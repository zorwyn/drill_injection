#!/usr/bin/env bash
set -euo pipefail

ACTION="${1:-run}"
DRY_RUN="${DRY_RUN:-true}"
AUTO_CLEANUP="${AUTO_CLEANUP:-true}"
GSQL_BIN="${GSQL_BIN:-gsql}"
DB_HOST="${DB_HOST:-127.0.0.1}"
DB_PORT="${DB_PORT:-5432}"
DB_NAME="${DB_NAME:-postgres}"
DB_USER="${DB_USER:-gaussdb}"
SCHEMA_NAME="${SCHEMA_NAME:-drill_bloat}"
TENANT_ID="${TENANT_ID:-7}"
SEED_ROWS="${SEED_ROWS:-500000}"
TENANT_MOD="${TENANT_MOD:-64}"
ITEMS_PER_ORDER="${ITEMS_PER_ORDER:-2}"
PAYLOAD_WIDTH="${PAYLOAD_WIDTH:-128}"
ITEM_PAYLOAD_WIDTH="${ITEM_PAYLOAD_WIDTH:-96}"
TXN_HOLD_SEC="${TXN_HOLD_SEC:-1800}"
CHURN_ROUNDS="${CHURN_ROUNDS:-180}"
UPDATE_BATCH="${UPDATE_BATCH:-5000}"
ITEM_UPDATE_BATCH="${ITEM_UPDATE_BATCH:-10000}"
SLEEP_MS="${SLEEP_MS:-500}"
LOOKBACK_MINUTES="${LOOKBACK_MINUTES:-1440}"
TOPN="${TOPN:-50}"
PROBE_INTERVAL_SEC="${PROBE_INTERVAL_SEC:-20}"
OBSERVE_INTERVAL_SEC="${OBSERVE_INTERVAL_SEC:-60}"
RUN_SETUP="${RUN_SETUP:-true}"
LOG_ROOT="${LOG_ROOT:-/tmp/gaussdb-fault-drill}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQL_DIR="${SCRIPT_DIR}/../assets/long-txn-dead-tuple-bloat"
RUN_ID="$(date '+%Y%m%d-%H%M%S')"
LOG_DIR="${LOG_ROOT}/${RUN_ID}"

mkdir -p "${LOG_DIR}"

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

base_cmd() {
  printf '%q ' \
    "${GSQL_BIN}" \
    -v ON_ERROR_STOP=1 \
    -h "${DB_HOST}" \
    -p "${DB_PORT}" \
    -d "${DB_NAME}" \
    -U "${DB_USER}" \
    -v "schema_name=${SCHEMA_NAME}" \
    -v "tenant_id=${TENANT_ID}" \
    -v "seed_rows=${SEED_ROWS}" \
    -v "tenant_mod=${TENANT_MOD}" \
    -v "items_per_order=${ITEMS_PER_ORDER}" \
    -v "payload_width=${PAYLOAD_WIDTH}" \
    -v "item_payload_width=${ITEM_PAYLOAD_WIDTH}" \
    -v "txn_hold_sec=${TXN_HOLD_SEC}" \
    -v "churn_rounds=${CHURN_ROUNDS}" \
    -v "update_batch=${UPDATE_BATCH}" \
    -v "item_update_batch=${ITEM_UPDATE_BATCH}" \
    -v "sleep_ms=${SLEEP_MS}" \
    -v "lookback_minutes=${LOOKBACK_MINUTES}" \
    -v "topn=${TOPN}"
}

run_sql_file() {
  local sql_file="$1"
  local log_file="$2"
  local cmd

  cmd="$(base_cmd)"
  cmd+=$(printf '%q ' -f "${sql_file}")

  if [[ "${DRY_RUN}" == "true" ]]; then
    log "DRY-RUN: ${cmd}"
    return 0
  fi

  bash -lc "${cmd}" >"${log_file}" 2>&1
}

start_background_sql() {
  local sql_file="$1"
  local log_file="$2"

  if [[ "${DRY_RUN}" == "true" ]]; then
    run_sql_file "${sql_file}" "${log_file}"
    return 0
  fi

  (
    run_sql_file "${sql_file}" "${log_file}"
  ) &
  echo $!
}

probe_loop() {
  if [[ "${DRY_RUN}" == "true" ]]; then
    run_sql_file "${SQL_DIR}/04_probe_once.sql" "${LOG_DIR}/probe.log"
    return 0
  fi

  while kill -0 "${LONG_TXN_PID}" >/dev/null 2>&1; do
    run_sql_file "${SQL_DIR}/04_probe_once.sql" "${LOG_DIR}/probe-$(date '+%H%M%S').log"
    sleep "${PROBE_INTERVAL_SEC}"
  done
}

observe_loop() {
  if [[ "${DRY_RUN}" == "true" ]]; then
    run_sql_file "${SQL_DIR}/05_observe.sql" "${LOG_DIR}/observe.log"
    return 0
  fi

  while kill -0 "${LONG_TXN_PID}" >/dev/null 2>&1; do
    run_sql_file "${SQL_DIR}/05_observe.sql" "${LOG_DIR}/observe-$(date '+%H%M%S').log"
    sleep "${OBSERVE_INTERVAL_SEC}"
  done
}

cleanup() {
  if [[ "${AUTO_CLEANUP}" != "true" ]]; then
    return 0
  fi

  run_sql_file "${SQL_DIR}/06_cleanup.sql" "${LOG_DIR}/cleanup.log" || true
}

precheck() {
  command -v "${GSQL_BIN}" >/dev/null 2>&1
  [[ -f "${SQL_DIR}/01_setup.sql" ]]
  [[ -f "${SQL_DIR}/02_hold_long_txn.sql" ]]
  [[ -f "${SQL_DIR}/03_dml_churn.sql" ]]
  [[ -f "${SQL_DIR}/04_probe_once.sql" ]]
  [[ -f "${SQL_DIR}/05_observe.sql" ]]
  [[ -f "${SQL_DIR}/06_cleanup.sql" ]]
}

run_action() {
  precheck

  if [[ "${RUN_SETUP}" == "true" ]]; then
    run_sql_file "${SQL_DIR}/01_setup.sql" "${LOG_DIR}/setup.log"
  fi

  LONG_TXN_PID="$(start_background_sql "${SQL_DIR}/02_hold_long_txn.sql" "${LOG_DIR}/long-txn.log")"

  if [[ "${DRY_RUN}" != "true" ]]; then
    sleep 2
  fi

  CHURN_PID="$(start_background_sql "${SQL_DIR}/03_dml_churn.sql" "${LOG_DIR}/dml-churn.log")"

  if [[ "${DRY_RUN}" == "true" ]]; then
    run_sql_file "${SQL_DIR}/04_probe_once.sql" "${LOG_DIR}/probe.log"
    run_sql_file "${SQL_DIR}/05_observe.sql" "${LOG_DIR}/observe.log"
    cleanup
    return 0
  fi

  probe_loop &
  PROBE_PID=$!

  observe_loop &
  OBSERVE_PID=$!

  wait "${CHURN_PID}"
  wait "${LONG_TXN_PID}"
  wait "${PROBE_PID}" || true
  wait "${OBSERVE_PID}" || true

  cleanup
  log "run completed; logs are in ${LOG_DIR}"
}

case "${ACTION}" in
  run)
    run_action
    ;;
  setup)
    precheck
    run_sql_file "${SQL_DIR}/01_setup.sql" "${LOG_DIR}/setup.log"
    ;;
  probe)
    precheck
    run_sql_file "${SQL_DIR}/04_probe_once.sql" "${LOG_DIR}/probe.log"
    ;;
  observe)
    precheck
    run_sql_file "${SQL_DIR}/05_observe.sql" "${LOG_DIR}/observe.log"
    ;;
  cleanup)
    precheck
    run_sql_file "${SQL_DIR}/06_cleanup.sql" "${LOG_DIR}/cleanup.log"
    ;;
  *)
    printf 'usage: %s [run|setup|probe|observe|cleanup]\n' "${0##*/}" >&2
    exit 2
    ;;
esac
