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

# OpenResty NGINX version must match the version installed in the runtime stage exactly.
# Use the NGINX version (drop the trailing ".N" from OpenResty version, N means number).
ARG NGINX_VERSION=1.31.1
# For Alpine-based images, change the following to 'musl'.
ARG LIBC_VERSION=glibc

ENV ARTI_PATH='https://artifact-public.instana.io/artifactory/shared/com/instana/nginx_otel/'

# Detect CPU arch (uname -m returns x86_64; Artifactory uses amd64).
# Download the single Instana nginx-otel zip that contains BOTH ssl1.1x and ssl3x .so variants.
RUN set -x; \
    download_key=$([ ! -z "${INSTANA_DOWNLOAD_KEY}" ] && echo "${INSTANA_DOWNLOAD_KEY}" || echo "${INSTANA_AGENT_KEY}"); \
    echo "Using download key ${download_key}; NGINX version: ${NGINX_VERSION}; LIBC version: ${LIBC_VERSION}"; \
    module_version=$(lynx -auth _:${download_key} -dump -listonly ${ARTI_PATH} | grep -o 'https:.*/[0-9]\+\.[0-9]\+\.[0-9]\+/' | rev | cut -d '/' -f 2 | rev | sort -V | tail -n1); \
    echo "Using Instana nginx-otel module version ${module_version} for OpenResty NGINX ${NGINX_VERSION}."; \
    ngx_arch="$(uname -m)"; \
    [ "$ngx_arch" = "x86_64" ] && ngx_arch="amd64"; \
    echo "CPU arch: ${ngx_arch}"; \
    tmp_dir="/tmp/nginx_tracing"; mkdir -p "${tmp_dir}"; \
    zip_name="linux-${ngx_arch}-${LIBC_VERSION}-openresty-${NGINX_VERSION}-otel.zip"; \
    curl --user "_:${download_key}" \
         --silent --show-error --fail \
         --output "${tmp_dir}/otel.zip" \
         "${ARTI_PATH}${module_version}/${zip_name}"; \
    cd "${tmp_dir}" && unzip -q otel.zip; \
    mkdir -p /opt/instana/nginx; \
    # Both SSL variants are extracted; the runtime entrypoint selects the right one.
    mv "openresty-${NGINX_VERSION}-otel_ssl1.1x.so" /opt/instana/nginx/ngx_otel_module_ssl1.1x.so; \
    mv "openresty-${NGINX_VERSION}-otel_ssl3x.so"   /opt/instana/nginx/ngx_otel_module_ssl3x.so


###################
# RESULTING IMAGE #
###################

# ─── Stage 2: Runtime image ──────────────────────────────────────────────────
FROM openresty/openresty:1.31.1.1-noble-amd64

# Install system dependencies and debugging tools
ENV DEBIAN_FRONTEND=noninteractive
RUN set -x \
  && apt-get update -y && apt-get upgrade -y \
  && apt-get install -y --no-install-recommends --no-install-suggests -y \
              apt-transport-https ca-certificates gnupg2 \
              cron libpopt0 logrotate lsb-release libcares2 \
              curl wget iproute2 vim

# Explicitly install lua-resty-http 0.18.0 with traceparent header support
RUN set -x; luarocks install lua-resty-http 0.18.0-0 && luarocks install lua-resty-openssl

# Add a script that prints the OpenResty version before starting it
COPY ./start_openresty /usr/local/openresty/bin/start_openresty

# Copy .so files in both SSL variants from stage 1.
COPY --from=tracing_dependencies /opt/instana/nginx/ngx_otel_module_ssl1.1x.so \
                                  /usr/local/lib/instana/ngx_otel_module_ssl1.1x.so
COPY --from=tracing_dependencies /opt/instana/nginx/ngx_otel_module_ssl3x.so \
                                  /usr/local/lib/instana/ngx_otel_module_ssl3x.so

# Detect the OpenSSL version baked into this image and create a fixed-path
# symlink at build time. nginx.conf always loads ngx_otel_module.so and never
# needs to know which SSL variant it points at.
# Ubuntu >= 24.04 → OpenSSL 3.x → ssl3x variant selected.
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

CMD ["/usr/local/openresty/bin/start_openresty"]
