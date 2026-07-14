#!/bin/sh
set -e

# Substitute environment variables into otel.yml before starting HAProxy
envsubst '${INSTANA_HOST_NAME}' \
  < /usr/local/etc/haproxy/otel.yml.template \
  > /usr/local/etc/haproxy/otel.yml

exec "$@"
