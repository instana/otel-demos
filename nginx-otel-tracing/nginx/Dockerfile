# ─── Stage 1: Download Instana NGINX OTel tracing .so files ─────────────────
FROM ubuntu:24.04 AS tracing_dependencies

RUN set -x \
  && apt-get update \
  && apt-get install --no-install-recommends --no-install-suggests -y \
       curl ca-certificates unzip lynx \
  && rm -rf /var/lib/apt/lists/*

# Instana Artifactory credentials — pass as build-args or override below.
# The download key takes precedence over the agent key when both are set.
ARG INSTANA_DOWNLOAD_KEY=instana_otel_downloadkey
ARG INSTANA_AGENT_KEY=instana_otel_downloadkey

# NGINX version must match the version installed in the runtime stage exactly.
ARG NGINX_VERSION=1.28.0
# For Alpine-based images change to 'musl'; ubuntu:24.04 uses glibc.
ARG LIBC_VERSION=glibc

ENV ARTI_PATH=https://artifact-public.instana.io/artifactory/shared/com/instana/nginx_otel/

# Detect CPU arch (uname -m returns x86_64; Artifactory uses amd64).
# Download the single zip that contains BOTH ssl1.1x and ssl3x .so variants.
RUN set -x; \
    download_key=$([ ! -z "${INSTANA_DOWNLOAD_KEY}" ] && echo "${INSTANA_DOWNLOAD_KEY}" || echo "${INSTANA_AGENT_KEY}"); \
    echo "Using download key ${download_key}; NGINX version: ${NGINX_VERSION}; LIBC version: ${LIBC_VERSION}"; \
    sensor_version=$(lynx -auth _:${download_key} -dump -listonly ${ARTI_PATH} | grep -o 'https:.*/[0-9]\+\.[0-9]\+\.[0-9]\+/' | rev | cut -d '/' -f 2 | rev | sort -V | tail -n1); \
    echo "Using sensor version ${sensor_version} for NGINX ${NGINX_VERSION}."; \
    ngx_arch="$(uname -m)"; \
    [ "$ngx_arch" = "x86_64" ] && ngx_arch="amd64"; \
    echo "CPU arch: ${ngx_arch}"; \
    tmp_dir="/tmp/nginx_tracing"; mkdir -p "${tmp_dir}"; \
    zip_name="linux-${ngx_arch}-${LIBC_VERSION}-nginx-${NGINX_VERSION}-otel.zip"; \
    curl --user "_:${download_key}" \
         --silent --show-error --fail \
         --output "${tmp_dir}/otel.zip" \
         "${ARTI_PATH}${sensor_version}/${zip_name}"; \
    cd "${tmp_dir}" && unzip -q otel.zip; \
    mkdir -p /opt/instana/nginx; \
    # Both SSL variants are extracted; the runtime entrypoint selects the right one.
    mv "nginx-${NGINX_VERSION}-otel_ssl1.1x.so" /opt/instana/nginx/ngx_otel_module_ssl1.1x.so; \
    mv "nginx-${NGINX_VERSION}-otel_ssl3x.so"   /opt/instana/nginx/ngx_otel_module_ssl3x.so

# ─── Stage 2: Runtime image ──────────────────────────────────────────────────
FROM ubuntu:24.04

ARG NGINX_VERSION=1.28.0

# Install system dependencies and add the official nginx.org repositories.
# Using apt-key add (legacy trusted keyring) — matches the confirmed-working
# pattern from the reference Dockerfile.
RUN set -x \
  && apt-get update \
  && apt-get install --no-install-recommends --no-install-suggests -y \
       curl apt-transport-https ca-certificates gnupg2 lsb-release openssl \
  && echo "deb http://nginx.org/packages/mainline/ubuntu/ $(lsb_release -sc) nginx" \
       >> /etc/apt/sources.list \
  && echo "deb http://nginx.org/packages/ubuntu/ $(lsb_release -sc) nginx" \
       >> /etc/apt/sources.list \
  && curl -fsSL https://nginx.org/keys/nginx_signing.key | apt-key add - \
  && apt-get update

# Pin NGINX to the exact version whose ABI the tracing .so was compiled against.
# apt-cache madison format: "nginx | <version> | <repo-url>"
# cut -d'|' -f2 extracts the version column; grep does a substring match so
# "1.28.0" matches "1.28.0-2~noble" (or any patch suffix the repo uses).
RUN set -x; \
    nginx_ver="$(apt-cache madison nginx | cut -d'|' -f2 \
        | tr -d '[:blank:]' | grep --fixed-strings "${NGINX_VERSION}" | head -1)"; \
    [ -z "$nginx_ver" ] && { echo "ERROR: NGINX ${NGINX_VERSION} not found in repo" >&2; exit 1; }; \
    apt-get install --no-install-recommends --no-install-suggests -y "nginx=${nginx_ver}"; \
    rm -f /etc/nginx/nginx.conf && rm -rf /etc/nginx/conf.d; \
    rm -rf /var/lib/apt/lists/*; \
    # Verify the binary is present at the expected path before the build succeeds.
    test -x /usr/sbin/nginx || { echo "ERROR: /usr/sbin/nginx not found after install" >&2; exit 1; }

# Copy both SSL-variant .so files from stage 1.
COPY --from=tracing_dependencies /opt/instana/nginx/ngx_otel_module_ssl1.1x.so \
                                  /usr/local/lib/instana/ngx_otel_module_ssl1.1x.so
COPY --from=tracing_dependencies /opt/instana/nginx/ngx_otel_module_ssl3x.so \
                                  /usr/local/lib/instana/ngx_otel_module_ssl3x.so

# Detect the OpenSSL version baked into this image and create a fixed-path
# symlink at build time. nginx.conf always loads ngx_otel_module.so and never
# needs to know which SSL variant it points at.
# ubuntu:24.04 → OpenSSL 3.x → ssl3x variant selected.
RUN set -x; \
    ssl_ver=$(openssl version | awk '{print $2}'); \
    case "$ssl_ver" in \
      1.1.*) variant="ssl1.1x" ;; \
      3.*)   variant="ssl3x"   ;; \
      *) echo "ERROR: Unsupported OpenSSL version '${ssl_ver}'" >&2; exit 1 ;; \
    esac; \
    ln -s "/usr/local/lib/instana/ngx_otel_module_${variant}.so" \
          /usr/local/lib/instana/ngx_otel_module.so; \
    echo "Symlink: ngx_otel_module.so → ngx_otel_module_${variant}.so"

CMD ["/usr/sbin/nginx", "-g", "daemon off;"]
