#!/usr/bin/env bash
set -euo pipefail

DRY_RUN="${DRY_RUN:-true}"
DURATION_SEC="${DURATION_SEC:-300}"
PRECHECK_CMD="${PRECHECK_CMD:-:}"
INJECT_CMD="${INJECT_CMD:-:}"
VERIFY_CMD="${VERIFY_CMD:-:}"
ROLLBACK_CMD="${ROLLBACK_CMD:-:}"

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

run_cmd() {
  if [[ "${DRY_RUN}" == "true" ]]; then
    log "DRY-RUN: $*"
    return 0
  fi
  bash -lc "$*"
}

rollback() {
  run_cmd "${ROLLBACK_CMD}"
}

trap rollback EXIT

main() {
  run_cmd "${PRECHECK_CMD}"
  run_cmd "${INJECT_CMD}"
  sleep "${DURATION_SEC}"
  run_cmd "${VERIFY_CMD}"
}

main "$@"
