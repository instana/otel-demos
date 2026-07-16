#!/bin/sh
set -e

# Substitute environment variables into otel.yml before starting HAProxy
envsubst '${INSTANA_HOST_NAME}' \
  < /usr/local/etc/haproxy/otel.yml.template \
  > /usr/local/etc/haproxy/otel.yml

# Redirect HAProxy stdout+stderr to a timestamped log file so the OTel plugin 
# debug output and access log are persisted on the host via the ./haproxy/logs volume mount.
LOG_DIR=/var/log/haproxy
LOG_FILE="${LOG_DIR}/haproxy-$(date +%s).log"
mkdir -p "${LOG_DIR}"

exec "$@" >>"${LOG_FILE}" 2>&1
