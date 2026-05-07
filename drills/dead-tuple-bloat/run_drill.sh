#!/usr/bin/env bash
set -euo pipefail

#
# 故障演练：长事务 → 死元组积压 → 查询计划退化
#
# 用法:
#   DRY_RUN=true  ./run_drill.sh          # 仅打印，不执行
#   DRY_RUN=false ./run_drill.sh          # 实际执行
#
# 必须设置的环境变量:
#   PGHOST, PGPORT, PGDATABASE, PGUSER, PGPASSWORD (或使用 .pgpass)
#

DRY_RUN="${DRY_RUN:-true}"
DRILL_DIR="$(cd "$(dirname "$0")" && pwd)"
TXN_HOLD_SEC="${TXN_HOLD_SEC:-900}"
OBSERVE_INTERVAL="${OBSERVE_INTERVAL:-60}"
LONG_TX_PID_FILE="${DRILL_DIR}/.long_tx_pid"

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }

run_sql() {
    local desc="$1" file="$2"
    log "=== ${desc} ==="
    if [[ "${DRY_RUN}" == "true" ]]; then
        log "DRY-RUN: gsql -f ${file}"
        return 0
    fi
    gsql -f "${file}" 2>&1 | while IFS= read -r line; do log "  ${line}"; done
}

run_sql_bg() {
    local desc="$1" file="$2"
    log "=== ${desc} (background) ==="
    if [[ "${DRY_RUN}" == "true" ]]; then
        log "DRY-RUN: gsql -f ${file} &"
        echo "0" > "${LONG_TX_PID_FILE}"
        return 0
    fi
    gsql -f "${file}" &
    echo "$!" > "${LONG_TX_PID_FILE}"
    log "长事务客户端 PID: $(cat "${LONG_TX_PID_FILE}")"
}

cleanup() {
    log "=== 执行回滚清理 ==="
    if [[ -f "${LONG_TX_PID_FILE}" ]]; then
        local client_pid
        client_pid=$(cat "${LONG_TX_PID_FILE}")
        if [[ "${client_pid}" -gt 0 ]] && kill -0 "${client_pid}" 2>/dev/null; then
            log "终止长事务客户端进程 ${client_pid}"
            kill "${client_pid}" 2>/dev/null || true
        fi
        rm -f "${LONG_TX_PID_FILE}"
    fi
    if [[ "${DRY_RUN}" != "true" ]]; then
        run_sql "SQL回滚清理" "${DRILL_DIR}/05_rollback_cleanup.sql"
    fi
    log "=== 回滚完成 ==="
}

trap cleanup EXIT

check_abort_conditions() {
    if [[ "${DRY_RUN}" == "true" ]]; then return 0; fi

    local conn_pct
    conn_pct=$(gsql -t -c "
        SELECT round(100.0 * count(*) / current_setting('max_connections')::int)
        FROM pg_stat_activity;" 2>/dev/null | tr -d ' ')

    if [[ -n "${conn_pct}" ]] && (( conn_pct > 80 )); then
        log "ABORT: 连接数超过 80% max_connections (${conn_pct}%)"
        return 1
    fi

    local lag
    lag=$(gsql -t -c "
        SELECT coalesce(max(
            extract(epoch from replay_lag)), 0)
        FROM pg_stat_replication;" 2>/dev/null | tr -d ' ')

    if [[ -n "${lag}" ]] && (( $(echo "${lag} > 60" | bc -l 2>/dev/null || echo 0) )); then
        log "ABORT: 复制延迟超过 60s (${lag}s)"
        return 1
    fi

    return 0
}

observe_loop() {
    local rounds=$1
    log "开始观测循环，共 ${rounds} 轮，间隔 ${OBSERVE_INTERVAL}s"
    for (( i=1; i<=rounds; i++ )); do
        log "--- 观测轮次 ${i}/${rounds} ---"

        if ! check_abort_conditions; then
            log "触发中止条件，提前退出"
            return 1
        fi

        if [[ "${DRY_RUN}" != "true" ]]; then
            gsql -t -c "
                SELECT 'dead_tuples=' || n_dead_tup,
                       'live_tuples=' || n_live_tup,
                       'dead_ratio=' || round(n_dead_tup::numeric / NULLIF(n_live_tup + n_dead_tup, 0), 4)
                FROM pg_stat_user_tables
                WHERE schemaname = 'fault_drill' AND relname = 'drill_orders';" \
                2>/dev/null | while IFS= read -r line; do [[ -n "$line" ]] && log "  ${line}"; done
        fi

        sleep "${OBSERVE_INTERVAL}"
    done
}

main() {
    log "========================================="
    log "故障演练: 长事务-死元组积压-计划退化"
    log "DRY_RUN=${DRY_RUN}"
    log "TXN_HOLD_SEC=${TXN_HOLD_SEC}"
    log "========================================="

    # Phase 0: 种子数据
    run_sql "Phase 0: 创建演练表和种子数据" "${DRILL_DIR}/01_setup_seed_data.sql"

    if [[ "${DRY_RUN}" != "true" ]]; then
        log "记录基线 EXPLAIN ..."
        gsql -c "EXPLAIN (ANALYZE, FORMAT TEXT)
            SELECT region, count(*), avg(amount)
            FROM fault_drill.drill_orders
            WHERE status = 'pending'
            GROUP BY region;" 2>&1 | while IFS= read -r line; do log "  BASELINE: ${line}"; done
    fi

    # Phase 1: 注入长事务
    run_sql_bg "Phase 1: 注入长事务 (持有 ${TXN_HOLD_SEC}s)" "${DRILL_DIR}/02_inject_long_transaction.sql"
    sleep 3

    # Phase 2: 产生死元组
    run_sql "Phase 2: 批量 UPDATE 产生死元组" "${DRILL_DIR}/03_generate_dead_tuples.sql"

    # Phase 3: 持续观测
    local observe_rounds=$(( TXN_HOLD_SEC / OBSERVE_INTERVAL ))
    [[ ${observe_rounds} -lt 1 ]] && observe_rounds=1

    observe_loop "${observe_rounds}" || true

    # Phase 3b: 对比 EXPLAIN
    run_sql "Phase 3: 观测计划退化" "${DRILL_DIR}/04_observe_plan_degradation.sql"

    log "========================================="
    log "注入阶段结束，进入自动回滚 (trap EXIT)"
    log "========================================="
}

main "$@"
