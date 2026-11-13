#!/bin/bash
# Wrapper around upstream dscontainer:
#  * DS_DM_PASSWORD_FILE  -> DS_DM_PASSWORD (dscontainer applies it on every start)
#  * DS_SUFFIX            -> creates backend + root entry on first start if missing
#  * DS_BACKEND           -> backend name for DS_SUFFIX (default: userroot)
set -euo pipefail

log() { echo "ds-entrypoint: $*" >&2; }

LDAPI_URL="ldapi://%2fdata%2frun%2fslapd-localhost.socket"

if [[ -n "${DS_DM_PASSWORD_FILE:-}" ]]; then
    if [[ ! -r "$DS_DM_PASSWORD_FILE" ]]; then
        log "DS_DM_PASSWORD_FILE=$DS_DM_PASSWORD_FILE is not readable"
        exit 1
    fi
    DS_DM_PASSWORD="$(tr -d '\r\n' < "$DS_DM_PASSWORD_FILE")"
    export DS_DM_PASSWORD
fi

# DN comparison: parse with python-ldap so whitespace around separators,
# attribute-type case and escaping (e.g. "\,") do not affect the result.
#   dn_tool check <dn>       -> exit 0 if <dn> is a valid, non-empty DN
#   dn_tool contains <dn>    -> exit 0 if <dn> is among "suffix (backend)" lines on stdin
# The script is passed with -c because stdin carries the suffix list.
DN_TOOL_PY=$(cat <<'PY'
import re
import sys

import ldap.dn


def norm(dn):
    parsed = ldap.dn.str2dn(dn)
    if not parsed:
        raise ValueError('empty DN')
    return ldap.dn.dn2str(parsed).lower()


mode, dn = sys.argv[1], sys.argv[2]
try:
    wanted = norm(dn)
except Exception:
    sys.exit(1)
if mode == 'contains':
    for line in sys.stdin:
        line = re.sub(r' \([^)]*\)$', '', line.rstrip('\r\n'))
        try:
            if norm(line) == wanted:
                sys.exit(0)
        except Exception:
            continue  # e.g. "No backends"
    sys.exit(1)
PY
)
dn_tool() { python3 -c "$DN_TOOL_PY" "$@"; }

# Create the root entry of a suffix if it is missing (LDAPI autobind as
# root). A first attempt interrupted by the server's initial restart can
# leave the backend without its root entry, and "backend exists" alone does
# not make the suffix usable.
ROOT_TOOL_PY=$(cat <<'PY'
import sys

import ldap
import ldap.dn
import ldap.modlist

url, suffix = sys.argv[1], sys.argv[2]
conn = ldap.initialize(url)
conn.sasl_non_interactive_bind_s('EXTERNAL')
try:
    conn.search_s(suffix, ldap.SCOPE_BASE, attrlist=['1.1'])
    sys.exit(0)
except ldap.NO_SUCH_OBJECT:
    pass
attr, value, _ = ldap.dn.str2dn(suffix)[0][0]
classes = {
    'dc': [b'top', b'domain'],
    'o': [b'top', b'organization'],
    'ou': [b'top', b'organizationalUnit'],
}.get(attr.lower(), [b'top', b'extensibleObject'])
conn.add_s(suffix, ldap.modlist.addModlist({'objectClass': classes, attr: [value.encode()]}))
print(f'created root entry {suffix}', file=sys.stderr)
PY
)
ensure_root() { python3 -c "$ROOT_TOOL_PY" "$LDAPI_URL" "$1"; }

if [[ -n "${DS_SUFFIX:-}" ]] && ! dn_tool check "$DS_SUFFIX"; then
    log "DS_SUFFIX=$DS_SUFFIX is not a valid DN"
    exit 1
fi

/usr/local/libexec/dirsrv/dscontainer -r &
pid=$!

interrupted=0
term() {
    interrupted=1
    kill -TERM "$pid" 2>/dev/null || true
}
trap term TERM INT

wait_healthy() {
    local timeout="${DS_STARTUP_TIMEOUT:-60}" i
    for ((i = 0; i < timeout; i += 2)); do
        kill -0 "$pid" 2>/dev/null || return 1
        if /usr/local/libexec/dirsrv/dscontainer -H >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
    done
    return 1
}

ensure_suffix() {
    local suffix="$1" backend="${DS_BACKEND:-userroot}"
    # Output lines look like "dc=example,dc=com (userroot)"; compare whole DNs so
    # "dc=com" does not match "dc=example,dc=com".
    if dsconf "$LDAPI_URL" backend suffix list 2>/dev/null \
        | dn_tool contains "$suffix"; then
        log "suffix $suffix already exists"
        return 0
    fi
    log "creating suffix $suffix (backend $backend)"
    dsconf "$LDAPI_URL" backend create --suffix "$suffix" --be-name "$backend" --create-suffix
}

# dscontainer applies DS_DM_PASSWORD once the server is up, which can be after
# the suffix exists (the suffix is created over LDAPI without a password).
# Report the suffix ready only when Directory Manager can bind with it, so
# that clients waiting for the log line can use the password at once. The
# password reaches ldapwhoami through a file descriptor, not the command line.
wait_dm_password() {
    [[ -n "${DS_DM_PASSWORD:-}" ]] || return 0
    local deadline=$((SECONDS + ${DS_STARTUP_TIMEOUT:-60}))
    while ((SECONDS < deadline)); do
        kill -0 "$pid" 2>/dev/null || return 1
        if ldapwhoami -x -H "$LDAPI_URL" -D "cn=Directory Manager" \
            -y <(printf '%s' "$DS_DM_PASSWORD") >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    return 1
}

# On first start dscontainer briefly runs the server while creating the
# instance and then restarts it, so a single health check can hit the
# temporary server. Retry until the suffix exists or the timeout expires.
if [[ -n "${DS_SUFFIX:-}" ]]; then
    deadline=$((SECONDS + ${DS_STARTUP_TIMEOUT:-60} * 2))
    while :; do
        if wait_healthy && ensure_suffix "$DS_SUFFIX" && ensure_root "$DS_SUFFIX"; then
            if wait_dm_password; then
                log "suffix $DS_SUFFIX ready"
            else
                log "WARNING: suffix $DS_SUFFIX exists, but the Directory Manager password was not accepted within ${DS_STARTUP_TIMEOUT:-60}s"
            fi
            break
        fi
        if ((SECONDS >= deadline)) || ! kill -0 "$pid" 2>/dev/null; then
            log "WARNING: failed to create suffix $DS_SUFFIX"
            break
        fi
        log "server not ready yet, retrying suffix creation"
        sleep 3
    done
fi

# A trapped signal interrupts wait (status > 128) without collecting the child,
# so wait again until dscontainer's own exit status is collected. Bash keeps the
# status of an exited child until it is waited for, so this works even if the
# child exits between the signal and the next wait. Status 127 means the status
# was already collected by the previous iteration (signal arrived just after it).
rc=0
while :; do
    interrupted=0
    status=0
    wait "$pid" || status=$?
    ((status == 127)) || rc=$status
    ((interrupted && status != 127)) || break
done
exit "$rc"
