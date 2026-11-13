# 389 Directory Server container

A Debian-based container image that builds [389 Directory Server](https://www.port389.org/)
from an official release tarball and verifies its SHA-256 checksum before compiling.

The default release is **3.3.1**. The image uses Debian `trixie-slim`, runs as
`dirsrv` (UID/GID `389:389`), and stores instance state in `/data`. It includes
`dsconf`, `dsctl`, LDAP client tools, a container healthcheck, and `tini` for
signal forwarding and process reaping.

The server and `lib389` come exclusively from the release build. The final image
installs runtime libraries and tools from Debian, without the Debian
`389-ds-base`, `389-ds-base-libs`, or `python3-lib389` packages.

## Quick start

Images are published to `ghcr.io/fomk/389-ds-base-docker` from
[github.com/fomk/389-ds-base-docker](https://github.com/fomk/389-ds-base-docker).

```sh
docker pull ghcr.io/fomk/389-ds-base-docker:latest
docker volume create dirsrv-data

docker run -d --name dirsrv \
  -p 127.0.0.1:3389:3389 \
  -p 127.0.0.1:3636:3636 \
  -v dirsrv-data:/data \
  -e DS_DM_PASSWORD='replace-with-a-strong-password' \
  -e DS_SUFFIX='dc=example,dc=com' \
  ghcr.io/fomk/389-ds-base-docker:latest
```

Ports in this example are bound to the host's loopback interface. Adjust the
bindings to make the directory accessible from other machines.

Inspect startup and health:

```sh
docker logs -f dirsrv
docker inspect --format '{{.State.Health.Status}}' dirsrv
```

First startup creates the instance, generates its initial TLS certificates, and
creates the requested suffix and root entry. Allow time for initialization.
The suffix wrapper retries through the server's initial restart; if it cannot
create the suffix, it logs a warning. It logs `ds-entrypoint: suffix <dn> ready`
only once the suffix exists and Directory Manager can bind with the configured
password, so clients may wait for that line. The healthcheck tests server availability,
so also check the suffix before relying on it.

## Configuration

| Variable | Default | Description |
| --- | --- | --- |
| `DS_DM_PASSWORD` | Unset | Password for `cn=Directory Manager`, applied on every startup. Set this or `DS_DM_PASSWORD_FILE` explicitly. |
| `DS_DM_PASSWORD_FILE` | Unset | Read the password from this file inside the container. Takes precedence over `DS_DM_PASSWORD`; CR and LF characters are removed. An unreadable file stops startup. |
| `DS_SUFFIX` | Unset | Create this suffix and its root entry if missing, for example `dc=example,dc=com`. If omitted, the wrapper does not create a backend. An invalid DN stops startup. Existing suffixes are matched as DNs, ignoring case and spaces around separators. |
| `DS_BACKEND` | `userroot` | Backend name used when creating `DS_SUFFIX`. |
| `DS_STARTUP_TIMEOUT` | `60` | Positive integer in seconds for each readiness wait during suffix creation. The retry deadline is twice this value and may be exceeded by an in-progress attempt. |

An existing suffix is reused on subsequent starts. Changing `DS_SUFFIX` adds a
suffix; it does not rename or migrate existing data. Use a distinct `DS_BACKEND`
when adding another suffix to the same instance.

### Password file

Mount a password file read-only and point `DS_DM_PASSWORD_FILE` at it:

```sh
docker run -d --name dirsrv \
  -p 127.0.0.1:3389:3389 \
  -p 127.0.0.1:3636:3636 \
  -v dirsrv-data:/data \
  --mount type=bind,src=/absolute/path/to/dm-password,dst=/run/secrets/dm-password,readonly \
  -e DS_DM_PASSWORD_FILE=/run/secrets/dm-password \
  -e DS_SUFFIX='dc=example,dc=com' \
  ghcr.io/fomk/389-ds-base-docker:latest
```

This is an alternative to the quick-start container; remove that container first
if reusing its name. The file must be readable by UID `389` inside the container.
Use file ownership and permissions appropriate to your secret storage.

## Ports, storage, and TLS

| Container path or port | Purpose |
| --- | --- |
| `3389/tcp` | LDAP |
| `3636/tcp` | LDAPS |
| `/data` | Persistent instance configuration, databases, certificates, logs, and runtime files |

Keep the same `/data` volume when replacing or upgrading the container. Named
volumes inherit the image's initial directory ownership; bind-mounted data
directories must be writable by UID/GID `389:389`.

### Standard ports 389 and 636

Inside the container the server listens on `3389` and `3636`. To serve LDAP on
the standard ports, map host ports `389` and `636` to them:

```sh
docker run -d --name dirsrv \
  --hostname ldap.example.com \
  -p 389:3389 \
  -p 636:3636 \
  -v dirsrv-data:/data \
  -e DS_DM_PASSWORD='replace-with-a-strong-password' \
  -e DS_SUFFIX='dc=example,dc=com' \
  ghcr.io/fomk/389-ds-base-docker:latest
```

The same with Docker Compose:

```yaml
services:
  dirsrv:
    image: ghcr.io/fomk/389-ds-base-docker:latest
    hostname: ldap.example.com
    ports:
      - "389:3389"
      - "636:3636"
    volumes:
      - dirsrv-data:/data
    environment:
      DS_DM_PASSWORD_FILE: /run/secrets/dm-password
      DS_SUFFIX: dc=example,dc=com
    secrets:
      - dm-password
    stop_grace_period: 30s

volumes:
  dirsrv-data:

secrets:
  dm-password:
    file: ./dm-password
```

Compose mounts `./dm-password` as-is, so the file must be readable by UID
`389`, for example `sudo chown 389 dm-password && sudo chmod 0400 dm-password`.

Clients then connect to `ldap://ldap.example.com:389` and
`ldaps://ldap.example.com:636`.

- Set the hostname to the name clients use. On first start the instance issues
  its TLS certificate for the container hostname; without `--hostname` that is a
  random container ID, and LDAPS clients reject the certificate. The certificate
  is created once, so changing the hostname later does not update it. Clients
  must also trust the generated CA, which they can copy with
  `docker cp dirsrv:/data/config/ca.crt .`
- These bindings listen on all host interfaces. Prefix them with an address,
  for example `127.0.0.1:389:3389`, to limit access. For production, consider
  replacing the generated certificate with one from your own CA (see below).
- The host ports must be free: stop any LDAP server already running on the
  host, such as `slapd` or another `ns-slapd` instance.
- Rootless Docker and Podman cannot bind host ports below 1024 by default.
  Allow it on the host with
  `sudo sysctl net.ipv4.ip_unprivileged_port_start=389`
  (add it to `/etc/sysctl.d/` to keep it after reboot), or keep unprivileged
  host ports such as `3389` and `3636`.
- The server is unaware of the external port. This only matters for
  absolute LDAP URLs it returns, such as referrals; normal searches and binds
  are unaffected.

The initial TLS certificate is issued by the instance's generated CA. Clients
must trust that CA and connect using a hostname covered by the server certificate.
Configure a certificate for your service hostname before exposing LDAPS to
remote clients.

## Administration

Use the local LDAPI socket to administer the instance from inside the container:

```sh
docker exec dirsrv dsconf \
  'ldapi://%2fdata%2frun%2fslapd-localhost.socket' backend suffix list

docker exec -it dirsrv ldapsearch -x \
  -H ldap://localhost:3389 \
  -D 'cn=Directory Manager' -W \
  -b 'dc=example,dc=com' -s base '(objectClass=*)'
```

Stop the instance with `docker stop dirsrv` so it can shut down cleanly.

## Build locally

```sh
docker build -t 389-ds-base:3.3.1 .
bash tests/smoke.sh 389-ds-base:3.3.1
```

The smoke test uses a temporary container and volume, publishes no host ports,
and removes its test resources on exit. It verifies that Debian server packages
are absent and ELF runtime dependencies resolve. It also checks health, the non-root user,
password-file handling, suffix creation, LDAP writes, LDAPS with certificate
verification, data persistence after container recreation, and clean shutdown.

To build another upstream release, supply the version and the SHA-256 of its
official `.tar.bz2` release asset:

```sh
docker build \
  --build-arg DS_VERSION='<version>' \
  --build-arg DS_SHA256='<sha256>' \
  -t '389-ds-base:<version>' .
```

`DS_UID` and `DS_GID` build arguments override the default UID/GID. The smoke
test expects the default UID `389`.

## GitHub Actions and GHCR

[`.github/workflows/image.yml`](.github/workflows/image.yml) builds and tests
`linux/amd64` images on branch pushes, release tag pushes, pull requests from forks,
and manual runs. Pull requests from branches of this repository are covered by
the push build, so they do not trigger a second run. Publication runs only after
the smoke test passes:

| Event | Published tags |
| --- | --- |
| Push or manual run on the default branch | `latest`, `sha-<full-commit-sha>` |
| Push or manual run on a release tag | The exact Git tag, for example `3.3.1`, plus `sha-<full-commit-sha>` |
| Pull request or another branch | Build and test only |

Release tags use the upstream 389 Directory Server version, for example `3.3.1`.
To publish a rebuild of the same server version (for example after a Debian
update or an entrypoint fix), add a container revision: `3.3.1-1`, `3.3.1-2`.
The workflow fails if the tag, without its revision suffix, does not match
`DS_VERSION` in the Dockerfile, so update `DS_VERSION` and `DS_SHA256` before
tagging a new upstream release:

```sh
git tag 3.3.1
git push origin 3.3.1
```

Use a release tag or commit tag when you need a stable image reference.

The workflow uses Buildx with the GitHub Actions cache and authenticates to GHCR
with the automatic `GITHUB_TOKEN` and `packages: write` permission. No separate
registry secret is needed. It sets the image source label to this repository
so GHCR can associate the package with the project.

Push these files to GitHub to enable the workflow. After the first successful
publication, make the package public in its GitHub package settings if anonymous
pulls are required. Private packages require a GHCR login with package read access.

See [GitHub's container publishing documentation](https://docs.github.com/en/actions/tutorials/publish-packages/publish-docker-images)
for repository and package permission details.
