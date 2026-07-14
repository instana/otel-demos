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
# Add an externally built NGINX OTel module for now (TODO: Replace this with a downloaded Instana module)
COPY ./ngx_otel_module.so /usr/local/openresty/nginx/modules/ngx_otel_module.so

#CMD ["/bin/sh", "-c", "while [ 1 ]; do sleep 1; done"]
CMD ["/usr/local/openresty/bin/start_openresty"]
