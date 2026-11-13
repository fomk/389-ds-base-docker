# syntax=docker/dockerfile:1

ARG DS_VERSION=3.3.1
ARG DS_SHA256=0a410a3231683e064e6a8d4f087881994970da36b8a0f3657e576012f53c98c4

FROM debian:trixie-slim AS builder

ARG DS_VERSION
ARG DS_SHA256

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      autoconf \
      automake \
      build-essential \
      bzip2 \
      ca-certificates \
      cargo \
      curl \
      ldap-utils \
      libbz2-dev \
      libcrack2-dev \
      libcurl4-openssl-dev \
      libdb-dev \
      libevent-dev \
      libicu-dev \
      libjson-c-dev \
      libkrb5-dev \
      libldap-dev \
      liblmdb-dev \
      libltdl-dev \
      libnspr4-dev \
      libnss3-dev \
      libpam0g-dev \
      libpci-dev \
      libpcre2-dev \
      libsasl2-dev \
      libsnmp-dev \
      libssl-dev \
      libsystemd-dev \
      libtool \
      pkgconf \
      python3-build \
      python3-argcomplete \
      python3-argparse-manpage \
      python3-cryptography \
      python3-dateutil \
      python3-dev \
      python3-ldap \
      python3-packaging \
      python3-pip \
      python3-selinux \
      python3-sepolicy \
      python3-setuptools \
      python3-wheel \
      rsync \
      rustc \
      zlib1g-dev \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /build

RUN curl --fail --location --proto '=https' --tlsv1.2 --retry 3 \
      --output 389-ds-base.tar.bz2 \
      "https://github.com/389ds/389-ds-base/releases/download/389-ds-base-${DS_VERSION}/389-ds-base-${DS_VERSION}.tar.bz2" \
 && echo "${DS_SHA256}  389-ds-base.tar.bz2" | sha256sum --check --strict \
 && mkdir source \
 && tar --extract --bzip2 --file 389-ds-base.tar.bz2 \
      --directory source --strip-components=1

WORKDIR /build/source

RUN autoreconf --force --install --verbose \
 && multiarch="$(dpkg-architecture --query DEB_HOST_MULTIARCH)" \
 && ./configure \
      --prefix=/usr \
      --exec-prefix=/usr \
      --bindir=/usr/bin \
      --sbindir=/usr/sbin \
      --sysconfdir=/etc \
      --datadir=/usr/share \
      --includedir=/usr/include \
      --libdir="/usr/lib/${multiarch}" \
      --libexecdir=/usr/libexec/dirsrv \
      --localstatedir=/var \
      --sharedstatedir=/var/lib \
      --mandir=/usr/share/man \
      --with-fhs \
      --with-libldap-r=no \
      --with-openldap \
      --with-systemd \
      --enable-rust-offline \
 && make -j"$(nproc)" \
 && make lib389 \
 && make DESTDIR=/opt/dirsrv install \
# Debian's Python install scheme maps --prefix=/usr to /usr/local, so lib389,
# dsconf/dsctl and dscontainer end up under /usr/local. Bytecode is compiled at
# build time because the non-root runtime user cannot write .pyc files.
 && python3 -m pip install \
      --break-system-packages \
      --no-deps \
      --prefix=/usr \
      --root=/opt/dirsrv \
      ./src/lib389/dist/*.whl

FROM debian:trixie-slim

ARG DS_VERSION
ARG DS_UID=389
ARG DS_GID=389

LABEL org.opencontainers.image.source="https://github.com/389ds/389-ds-base" \
      org.opencontainers.image.version="${DS_VERSION}"

ENV DEBIAN_FRONTEND=noninteractive

# Install runtime libraries and tools explicitly. The server and lib389 are
# supplied exclusively by the release build, without Debian's 389-ds packages.
RUN groupadd --system --gid "${DS_GID}" dirsrv \
 && useradd --system --uid "${DS_UID}" --gid dirsrv --home-dir /data \
      --no-create-home --shell /usr/sbin/nologin dirsrv \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates \
      ldap-utils \
      libcrack2 \
      libcrypt1 \
      libgcc-s1 \
      libicu76 \
      libjson-c5 \
      libkrb5-3 \
      libldap2 \
      liblmdb0 \
      libnspr4 \
      libnss3 \
      libnss3-tools \
      libpam0g \
      libpcre2-8-0 \
      libsasl2-2 \
      libsasl2-modules \
      libsasl2-modules-gssapi-mit \
      libsnmp40t64 \
      libssl3t64 \
      libstdc++6 \
      libsystemd0 \
      openssl \
      python3 \
      python3-argcomplete \
      python3-argparse-manpage \
      python3-cryptography \
      python3-dateutil \
      python3-distro \
      python3-ldap \
      python3-packaging \
      python3-psutil \
      python3-pyasn1 \
      python3-pyasn1-modules \
      tini \
      zlib1g \
 && rm -rf /var/lib/apt/lists/*

COPY --from=builder /opt/dirsrv/ /

RUN ldconfig \
 && mkdir -p /etc/dirsrv /data/config /data/ssca /data/run \
 && ln -s /data/config /etc/dirsrv/slapd-localhost \
 && ln -s /data/ssca /etc/dirsrv/ssca \
 && chown -R dirsrv:dirsrv /data

COPY --chmod=0755 entrypoint.sh /usr/local/bin/ds-entrypoint

USER dirsrv
VOLUME /data
EXPOSE 3389 3636

HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
  CMD ["/usr/local/libexec/dirsrv/dscontainer", "-H"]

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/ds-entrypoint"]
