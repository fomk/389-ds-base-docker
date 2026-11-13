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

# On first start dscontainer briefly runs the server while creating the
# instance and then restarts it, so a single health check can hit the
# temporary server. Retry until the suffix exists or the timeout expires.
if [[ -n "${DS_SUFFIX:-}" ]]; then
    deadline=$((SECONDS + ${DS_STARTUP_TIMEOUT:-60} * 2))
    while :; do
        if wait_healthy && ensure_suffix "$DS_SUFFIX"; then
            log "suffix $DS_SUFFIX ready"
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
