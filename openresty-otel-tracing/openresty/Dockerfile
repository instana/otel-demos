FROM ubuntu:24.04 AS tracing_dependencies

RUN set -x \
  && apt-get update \
  && apt-get install --no-install-recommends --no-install-suggests -y \
    lynx curl ca-certificates gnupg2 unzip

ARG download_key
ARG agent_key
ARG openresty_version=1.31.1.1
# For Alpine-based images, change the following to 'musl'
ARG libc_version=glibc

ENV INSTANA_DOWNLOAD_KEY=${download_key}
ENV INSTANA_AGENT_KEY=${agent_key}
ENV OPENRESTY_VERSION=${openresty_version}
ENV LIBC_VERSION=${libc_version}
ENV ARTI_PATH='https://artifact-public.instana.io/artifactory/shared/com/instana/nginx_otel/'

# Download extension from Artifactory
RUN download_key=$([ ! -z "${INSTANA_DOWNLOAD_KEY}" ] && echo "${INSTANA_DOWNLOAD_KEY}" || echo "${INSTANA_AGENT_KEY}"); \
    echo "Using download key ${download_key}; OpenResty version: ${OPENRESTY_VERSION}; LIBC version: ${LIBC_VERSION}"; \
    ngx_otel_version=$(lynx -auth _:${download_key} -dump -listonly ${ARTI_PATH} | grep -o 'https:.*/[0-9]\+\.[0-9]\+\.[0-9]\+/' | rev | cut -d '/' -f 2 | rev | sort -V | tail -n1); \
    echo "Using ngx_otel version ${ngx_otel_version} for OpenResty ${OPENRESTY_VERSION}."; \
    tmp_file="tmp.zip"; tmp_dir="/tmp/nginx_otel"; mkdir -p "${tmp_dir}" && cd "${tmp_dir}" && \
    ngx_arch="$(uname -m)" && if [ "$ngx_arch" = "x86_64" ]; then ngx_arch="amd64"; fi; echo "CPU arch: ${ngx_arch}"; \
    curl --user _:${download_key} --silent --output ${tmp_file} ${ARTI_PATH}${ngx_otel_version}/linux-${ngx_arch}-${LIBC_VERSION}-openresty-${OPENRESTY_VERSION}-compat-otel.zip --fail && \
    unzip ${tmp_file} && \
    mkdir -p /opt/instana/nginx && \
    mv ${LIBC_VERSION}-openresty-${OPENRESTY_VERSION}-compat-ngx_otel_module_ssl3x.so /opt/instana/nginx/ngx_otel_module.so


###################
# RESULTING IMAGE #
###################

FROM openresty/openresty:1.31.1.1-noble-amd64

ENV DEBIAN_FRONTEND=noninteractive
RUN set -x \
  && apt-get update -y && apt-get upgrade -y \
  && apt-get install -y --no-install-recommends --no-install-suggests -y \
              curl wget apt-transport-https ca-certificates iproute2 gnupg2 \
              cron libpopt0 logrotate lsb-release libcares2 vim

# Explicitly install lua-resty-http 0.18.0 with traceparent header support
RUN set -x; luarocks install lua-resty-http 0.18.0-0 && luarocks install lua-resty-openssl

# Add a script that prints the OpenResty version before starting it
COPY ./start_openresty /usr/local/openresty/bin/start_openresty

# Add Instana NGINX OTel module from Artifactory
COPY --from=tracing_dependencies /opt/instana/nginx/ngx_otel_module.so /usr/local/openresty/nginx/modules/ngx_otel_module.so

# Instana developers only: Add an externally built Instana NGINX OTel module instead
#COPY ./ngx_otel_module.so /usr/local/openresty/nginx/modules/ngx_otel_module.so

#CMD ["/bin/sh", "-c", "while [ 1 ]; do sleep 1; done"]
CMD ["/usr/local/openresty/bin/start_openresty"]
