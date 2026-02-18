#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# Production-grade MySQL replica bootstrap (RDS -> local Docker)
#
# - Waits for local MySQL using socket (works with entrypoint temp server)
# - Takes consistent seed dump from cloud (mysqldump --single-transaction)
# - Automatically reads source binlog file/pos via SHOW MASTER STATUS
# - Configures classic file/position replication (GTID not required)
# - Idempotent on restarts: if replication is already configured, exits
#
# NOTE:
# This script runs ONLY when /var/lib/mysql is empty (fresh init),
# because MySQL official image only executes /docker-entrypoint-initdb.d/*
# during first initialization.
# ------------------------------------------------------------

log() { echo "[init] $*"; }

# ---------- Required env vars ----------
: "${MYSQL_ROOT_PASSWORD?Need MYSQL_ROOT_PASSWORD}"

: "${CLOUD_HOST?Need CLOUD_HOST}"
: "${CLOUD_PORT?Need CLOUD_PORT}"
: "${CLOUD_DB?Need CLOUD_DB}"

# Replication user (REPLICATION SLAVE/CLIENT on source)
: "${CLOUD_REPL_USER?Need CLOUD_REPL_USER}"
: "${CLOUD_REPL_PASSWORD?Need CLOUD_REPL_PASSWORD}"

# Admin user used ONLY for dump + SHOW MASTER STATUS (read-only access is enough if granted)
: "${CLOUD_ADMIN_USER?Need CLOUD_ADMIN_USER}"
: "${CLOUD_ADMIN_PASSWORD?Need CLOUD_ADMIN_PASSWORD}"

# Optional safety knobs
CLOUD_CONNECT_TIMEOUT="${CLOUD_CONNECT_TIMEOUT:-10}"
LOCAL_DB="${LOCAL_DB:-${CLOUD_DB}}"

mkdir -p /meta /backups || true

# ---------- Wait for local MySQL (socket-based) ----------
log "waiting for local mysql (socket)..."
until mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" -e "SELECT 1" >/dev/null 2>&1; do
  sleep 2
done

# ---------- Stable identity (not strictly needed for file/pos, but useful for tracing) ----------
ID_FILE="/meta/replica_id"
if [[ ! -f "$ID_FILE" ]]; then
  date +%s%N | sha256sum | awk '{print substr($1,1,10)}' > "$ID_FILE"
fi
RID="$(cat "$ID_FILE")"
log "replica_id=$RID"

# ---------- Idempotency: if replication already configured, exit ----------
HAS_REPL=$(
  mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" -Nse \
    "SELECT COUNT(*) FROM performance_schema.replication_connection_configuration;" \
  2>/dev/null || true
)

if [[ "${HAS_REPL}" != "0" ]]; then
  log "replication already configured, ensuring read-only + exiting."
  mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" -e "
    SET GLOBAL read_only = ON;
    SET GLOBAL super_read_only = ON;
  " || true
  exit 0
fi

# ---------- Fetch source binlog coordinates ----------
log "fetching source MASTER STATUS (binlog file/pos)..."
MASTER_STATUS=$(
  mysql \
    --protocol=tcp \
    -h "${CLOUD_HOST}" -P "${CLOUD_PORT}" \
    -u "${CLOUD_ADMIN_USER}" -p"${CLOUD_ADMIN_PASSWORD}" \
    --connect-timeout="${CLOUD_CONNECT_TIMEOUT}" \
    -Nse "SHOW MASTER STATUS;" 2>/dev/null || true
)

if [[ -z "${MASTER_STATUS}" ]]; then
  log "ERROR: SHOW MASTER STATUS returned empty. On RDS, log_bin must be ON and source must be writer."
  log "Fix on RDS: enable binary logging (parameter group) and reboot if needed."
  exit 1
fi

# MASTER_STATUS columns: File Position Binlog_Do_DB Binlog_Ignore_DB Executed_Gtid_Set
SOURCE_LOG_FILE="$(awk '{print $1}' <<<"${MASTER_STATUS}")"
SOURCE_LOG_POS="$(awk '{print $2}' <<<"${MASTER_STATUS}")"

if [[ -z "${SOURCE_LOG_FILE}" || -z "${SOURCE_LOG_POS}" ]]; then
  log "ERROR: Could not parse MASTER STATUS output: ${MASTER_STATUS}"
  exit 1
fi

log "source binlog file=${SOURCE_LOG_FILE} pos=${SOURCE_LOG_POS}"

# ---------- Seed dump from cloud ----------
log "taking cloud dump for initial seed..."
# --single-transaction: consistent snapshot (InnoDB)
# --routines --triggers: keep DB objects if needed
# --set-gtid-purged=OFF: safe for RDS + non-GTID replication
mysqldump \
  --protocol=tcp \
  -h "${CLOUD_HOST}" -P "${CLOUD_PORT}" \
  -u "${CLOUD_ADMIN_USER}" -p"${CLOUD_ADMIN_PASSWORD}" \
  --single-transaction --routines --triggers --events \
  --set-gtid-purged=OFF \
  "${CLOUD_DB}" > "/backups/seed.sql"

# Quick sanity check
if [[ ! -s "/backups/seed.sql" ]]; then
  log "ERROR: seed dump is empty. Check source creds/permissions."
  exit 1
fi

log "importing seed into local database ${LOCAL_DB}..."
# Ensure DB exists (mysql image already created MYSQL_DATABASE, but keep safe)
mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" -e "CREATE DATABASE IF NOT EXISTS \`${LOCAL_DB}\`;"

mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" "${LOCAL_DB}" < "/backups/seed.sql"

# ---------- Configure replication (classic file/pos) ----------
log "configuring replication (file/position, GTID not required)..."
mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" -e "
STOP REPLICA;
RESET REPLICA ALL;

CHANGE REPLICATION SOURCE TO
  SOURCE_HOST='${CLOUD_HOST}',
  SOURCE_PORT=${CLOUD_PORT},
  SOURCE_USER='${CLOUD_REPL_USER}',
  SOURCE_PASSWORD='${CLOUD_REPL_PASSWORD}',
  SOURCE_SSL=1,
  SOURCE_AUTO_POSITION=0,
  SOURCE_LOG_FILE='${SOURCE_LOG_FILE}',
  SOURCE_LOG_POS=${SOURCE_LOG_POS};

START REPLICA;
"

# ---------- Make replica read-only ----------
log "enabling read-only on replica..."
mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" -e "
  SET GLOBAL read_only = ON;
  SET GLOBAL super_read_only = ON;
"

# ---------- Final check ----------
log "verifying replica threads..."
STATUS=$(
  mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" -Nse \
    "SHOW REPLICA STATUS\G" 2>/dev/null || true
)

# Best-effort display key lines
echo "${STATUS}" | egrep -i "Replica_IO_Running:|Replica_SQL_Running:|Last_IO_Error:|Last_SQL_Error:|Seconds_Behind_Source:|Auto_Position:" || true

log "done."

