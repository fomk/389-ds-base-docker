#!/usr/bin/env bash
set -euo pipefail

image="${1:-389-ds-base:3.3.1}"
name="ds-smoke-$(date +%s)-$$"
volume="${name}-data"
password='Smoke-389-test-Password'
suffix='dc=smoke,dc=test'

cleanup() {
    local status=$?
    if ((status != 0)); then
        docker logs --tail 150 "$name" >&2 || true
    fi
    docker rm -f -v "$name" >/dev/null 2>&1 || true
    docker volume rm "$volume" >/dev/null 2>&1 || true
    exit "$status"
}
trap cleanup EXIT

# Reject accidental mixing of the source build with Debian's server packages.
# Check plugin dependencies too: a successful server start alone does not load
# every optional plugin or standalone tool.
docker run --rm -i --entrypoint python3 "$image" - <<'PY'
from pathlib import Path
import subprocess

packages = subprocess.check_output(
    ['dpkg-query', '-W', '-f=${binary:Package} ${db:Status-Status}\n'], text=True
)
for line in packages.splitlines():
    package, status = line.split()
    package = package.split(':')[0]
    assert not (status == 'installed' and (
        package.startswith('389-ds-base') or package == 'python3-lib389'
    )), f'Unexpected Debian server package: {package}'

paths = set(Path('/usr/bin').iterdir()) | set(Path('/usr/sbin').iterdir())
for directory in Path('/usr/lib').glob('*/dirsrv'):
    paths.update(directory.rglob('*'))
for path in sorted(paths):
    if path.is_file() and not path.is_symlink():
        with path.open('rb') as binary:
            if binary.read(4) != b'\x7fELF':
                continue
        result = subprocess.run(['ldd', str(path)], capture_output=True, text=True)
        assert 'not found' not in result.stdout + result.stderr, (
            f'Unresolved runtime dependency: {path}\n{result.stdout}{result.stderr}'
        )
print('Source-only server installation and ELF dependencies verified')
PY

start() {
    docker run -d --name "$name" \
        --mount "type=volume,source=$volume,target=/data" \
        -e DS_DM_PASSWORD_FILE=/data/smoke-password \
        -e "DS_SUFFIX=$suffix" \
        -e DS_BACKEND=smoketest \
        -e DS_STARTUP_TIMEOUT=90 \
        "$image" >/dev/null
}

wait_ready() {
    local i
    for ((i = 0; i < 90; i++)); do
        if [[ "$(docker inspect -f '{{.State.Running}}' "$name")" != true ]]; then
            echo 'Container exited before becoming ready' >&2
            return 1
        fi
        if [[ "$(docker inspect -f '{{.State.Health.Status}}' "$name")" == healthy ]] &&
            docker exec "$name" ldapsearch -x -H ldap://localhost:3389 \
                -D 'cn=Directory Manager' -w "$password" \
                -b "$suffix" -s base '(objectClass=*)' dn >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
    done
    echo 'Timed out waiting for healthcheck and suffix' >&2
    return 1
}

stop_cleanly() {
    docker stop --timeout 30 "$name" >/dev/null
    [[ "$(docker inspect -f '{{.State.ExitCode}}' "$name")" == 0 ]]
}

docker volume create "$volume" >/dev/null
# Include CRLF to exercise password-file normalization in the entrypoint.
docker run --rm --entrypoint /bin/sh \
    --mount "type=volume,source=$volume,target=/data" \
    "$image" -ec 'umask 077; printf "%s\r\n" "$1" > /data/smoke-password' sh "$password"

start
wait_ready
[[ "$(docker exec "$name" id -u)" == 389 ]]

docker exec -i "$name" python3 - <<'PY'
from pathlib import Path
import ldap

password = Path('/data/smoke-password').read_text().strip('\r\n')
for url in ('ldap://localhost:3389', 'ldaps://localhost:3636'):
    conn = ldap.initialize(url)
    conn.set_option(ldap.OPT_NETWORK_TIMEOUT, 5)
    if url.startswith('ldaps:'):
        conn.set_option(ldap.OPT_X_TLS_CACERTFILE, '/data/config/ca.crt')
        conn.set_option(ldap.OPT_X_TLS_REQUIRE_CERT, ldap.OPT_X_TLS_DEMAND)
        conn.set_option(ldap.OPT_X_TLS_NEWCTX, 0)
    conn.simple_bind_s('cn=Directory Manager', password)
    assert len(conn.search_s('dc=smoke,dc=test', ldap.SCOPE_BASE)) == 1
    if url.startswith('ldap:'):
        conn.add_s('ou=persisted,dc=smoke,dc=test', [
            ('objectClass', [b'top', b'organizationalUnit']),
            ('ou', [b'persisted']),
        ])
    assert len(conn.search_s('ou=persisted,dc=smoke,dc=test', ldap.SCOPE_BASE)) == 1
    conn.unbind_s()
    print(f'{url}: authenticated LDAP checks passed')
PY

stop_cleanly
docker rm "$name" >/dev/null
start
wait_ready
docker exec "$name" ldapsearch -x -H ldap://localhost:3389 \
    -D 'cn=Directory Manager' -w "$password" \
    -b "ou=persisted,$suffix" -s base '(objectClass=*)' dn >/dev/null
stop_cleanly
echo 'Smoke test passed: health, non-root user, password file, LDAP, verified LDAPS, persistence, shutdown'
