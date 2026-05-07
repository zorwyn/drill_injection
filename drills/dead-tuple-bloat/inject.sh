#!/usr/bin/env bash
###############################################################################
# dead-tuple-bloat 故障注入脚本
#
# 故障链路: 长事务 → 死元组积压 → 计划生成慢 → SQL 整体变慢
#
# 使用方式:
#   DRY_RUN=false GSQL="gsql -d mydb -p 5432" ./inject.sh
#
# 退出即清理 — Ctrl+C / 正常退出 / SSH 断开 都会自动回滚
###############################################################################
set -uo pipefail

# ── 参数 ─────────────────────────────────────────────────────────────────────
GSQL="${GSQL:-gsql -d postgres -p 5432}"       # 连接命令
DRY_RUN="${DRY_RUN:-true}"                     # true 只打印不执行
SCHEMA="${SCHEMA:-fault_drill}"                # 演练 schema
TABLE="${TABLE:-drill_orders}"                 # 目标表
SEED_ROWS="${SEED_ROWS:-500000}"               # 种子数据行数
UPDATE_ROWS="${UPDATE_ROWS:-200000}"           # 每轮更新行数
UPDATE_ROUNDS="${UPDATE_ROUNDS:-5}"            # 更新轮次(制造死元组)
OBSERVE_INTERVAL="${OBSERVE_INTERVAL:-30}"     # 观测采集间隔(秒)

# ── 内部状态 ──────────────────────────────────────────────────────────────────
LONG_TX_PID=""                                 # 后台长事务的 shell PID
LONG_TX_BACKEND=""                             # gaussdb backend pid
INJECTED=false                                 # 是否已注入
SEED_CREATED=false                             # 是否已创建种子数据
BASELINE_COST=""                               # 基线 EXPLAIN cost

# ── 工具函数 ──────────────────────────────────────────────────────────────────
log()  { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
info() { log "INFO  $*"; }
warn() { log "WARN  $*"; }
err()  { log "ERROR $*"; }

sql() {
  if [[ "${DRY_RUN}" == "true" ]]; then
    log "DRY-RUN SQL: $1"
    return 0
  fi
  ${GSQL} -t -A -c "$1" 2>&1
}

sql_quiet() {
  if [[ "${DRY_RUN}" == "true" ]]; then
    return 0
  fi
  ${GSQL} -t -A -c "$1" >/dev/null 2>&1
}

# ── 清理 (trap EXIT) ─────────────────────────────────────────────────────────
cleanup() {
  local exit_code=$?
  echo ""
  info "========================================="
  info "清理开始 (exit_code=${exit_code})"
  info "========================================="

  # 1. 杀掉长事务
  if [[ -n "${LONG_TX_PID}" ]]; then
    info "终止长事务 shell 进程 (pid=${LONG_TX_PID})"
    kill "${LONG_TX_PID}" 2>/dev/null || true
    wait "${LONG_TX_PID}" 2>/dev/null || true
  fi

  if [[ -n "${LONG_TX_BACKEND}" ]] && [[ "${DRY_RUN}" != "true" ]]; then
    info "pg_terminate_backend(${LONG_TX_BACKEND})"
    sql "SELECT pg_terminate_backend(${LONG_TX_BACKEND});" || true
  fi

  # 2. 清理所有本次演练遗留的长事务 (按 application_name 识别)
  if [[ "${DRY_RUN}" != "true" ]]; then
    info "清理所有 fault_drill 标记的后端进程"
    sql "SELECT pg_terminate_backend(pid)
         FROM pg_stat_activity
         WHERE application_name = 'fault_drill_long_tx'
           AND state = 'idle in transaction';" || true
  fi

  # 3. VACUUM 目标表
  if [[ "${INJECTED}" == "true" ]]; then
    info "VACUUM ANALYZE ${SCHEMA}.${TABLE}"
    sql "VACUUM ANALYZE ${SCHEMA}.${TABLE};" || true
  fi

  # 4. 清理种子数据 (可选 — 默认保留，取消注释下一行则删除)
  # if [[ "${SEED_CREATED}" == "true" ]]; then
  #   info "DROP SCHEMA ${SCHEMA} CASCADE"
  #   sql "DROP SCHEMA IF EXISTS ${SCHEMA} CASCADE;" || true
  # fi

  # 5. 最终状态确认
  if [[ "${DRY_RUN}" != "true" ]]; then
    info "清理后死元组数:"
    sql "SELECT n_dead_tup FROM pg_stat_user_tables
         WHERE schemaname='${SCHEMA}' AND relname='${TABLE}';" || true
  fi

  info "清理完成"
}

trap cleanup EXIT INT TERM HUP

# ── Phase 0: 前置检查 ────────────────────────────────────────────────────────
precheck() {
  info "===== Phase 0: 前置检查 ====="

  # 检查连接
  if [[ "${DRY_RUN}" != "true" ]]; then
    sql "SELECT 1;" >/dev/null || { err "无法连接数据库"; exit 1; }
    info "数据库连接正常"
  fi

  # 检查是否存在长事务
  if [[ "${DRY_RUN}" != "true" ]]; then
    local long_tx_count
    long_tx_count=$(sql "SELECT count(*) FROM pg_stat_activity
                         WHERE state = 'idle in transaction'
                           AND now() - xact_start > interval '5 minutes';")
    if [[ "${long_tx_count}" -gt 0 ]]; then
      warn "已存在 ${long_tx_count} 个长事务，可能影响演练结果"
    fi
  fi

  info "前置检查通过"
}

# ── Phase 1: 创建种子数据 ────────────────────────────────────────────────────
setup_seed() {
  info "===== Phase 1: 创建种子数据 (${SEED_ROWS} 行) ====="

  sql "CREATE SCHEMA IF NOT EXISTS ${SCHEMA};"
  sql "DROP TABLE IF EXISTS ${SCHEMA}.${TABLE};"
  sql "CREATE TABLE ${SCHEMA}.${TABLE} (
         id         BIGSERIAL PRIMARY KEY,
         user_id    INT            NOT NULL,
         amount     NUMERIC(12,2)  NOT NULL,
         status     VARCHAR(20)    NOT NULL DEFAULT 'pending',
         region     VARCHAR(10)    NOT NULL,
         created_at TIMESTAMP      NOT NULL DEFAULT now(),
         updated_at TIMESTAMP      NOT NULL DEFAULT now(),
         padding    VARCHAR(200)   NOT NULL DEFAULT repeat('x', 200)
       );"
  sql "CREATE INDEX idx_drill_status ON ${SCHEMA}.${TABLE}(status);"
  sql "CREATE INDEX idx_drill_user   ON ${SCHEMA}.${TABLE}(user_id);"
  sql "CREATE INDEX idx_drill_region ON ${SCHEMA}.${TABLE}(region);"

  sql "INSERT INTO ${SCHEMA}.${TABLE} (user_id, amount, status, region)
       SELECT
         (random()*10000)::INT,
         (random()*9999+1)::NUMERIC(12,2),
         (ARRAY['pending','paid','shipped','done','cancelled'])[floor(random()*5+1)::INT],
         (ARRAY['east','west','north','south','central'])[floor(random()*5+1)::INT]
       FROM generate_series(1, ${SEED_ROWS});"

  sql "ANALYZE ${SCHEMA}.${TABLE};"
  SEED_CREATED=true
  info "种子数据就绪"
}

# ── Phase 2: 记录基线 ────────────────────────────────────────────────────────
record_baseline() {
  info "===== Phase 2: 记录基线 ====="

  if [[ "${DRY_RUN}" != "true" ]]; then
    local dead_tup
    dead_tup=$(sql "SELECT n_dead_tup FROM pg_stat_user_tables
                    WHERE schemaname='${SCHEMA}' AND relname='${TABLE}';")
    info "基线死元组数: ${dead_tup}"

    BASELINE_COST=$(sql "EXPLAIN SELECT count(*) FROM ${SCHEMA}.${TABLE}
                         WHERE status='pending' AND region='east'
                         GROUP BY user_id ORDER BY count(*) DESC LIMIT 10;" \
                    | head -1)
    info "基线 EXPLAIN: ${BASELINE_COST}"
  else
    info "DRY-RUN: 跳过基线采集"
  fi
}

# ── Phase 3: 注入长事务 ──────────────────────────────────────────────────────
start_long_transaction() {
  info "===== Phase 3: 注入长事务 ====="

  if [[ "${DRY_RUN}" == "true" ]]; then
    log "DRY-RUN: 将开启长事务并 hold 住, 阻止 autovacuum 回收"
    return 0
  fi

  # 后台开一个事务，设置 application_name 方便识别和清理
  (
    ${GSQL} <<'EOSQL'
SET application_name = 'fault_drill_long_tx';
BEGIN;
-- 读一行来固定快照 (snapshot pinning)
SELECT * FROM fault_drill.drill_orders LIMIT 1;
-- 持续持有，直到被外部 kill
SELECT pg_sleep(86400);
EOSQL
  ) &
  LONG_TX_PID=$!
  sleep 2

  # 找到对应的 backend pid
  LONG_TX_BACKEND=$(sql "SELECT pid FROM pg_stat_activity
                         WHERE application_name = 'fault_drill_long_tx'
                           AND state = 'idle in transaction'
                         ORDER BY xact_start LIMIT 1;")
  info "长事务已启动 (shell_pid=${LONG_TX_PID}, backend_pid=${LONG_TX_BACKEND})"
}

# ── Phase 4: 制造死元组 ──────────────────────────────────────────────────────
generate_dead_tuples() {
  info "===== Phase 4: 批量 UPDATE 制造死元组 (${UPDATE_ROUNDS} 轮 x ${UPDATE_ROWS} 行) ====="

  for round in $(seq 1 "${UPDATE_ROUNDS}"); do
    info "第 ${round}/${UPDATE_ROUNDS} 轮 UPDATE..."
    sql "UPDATE ${SCHEMA}.${TABLE}
         SET    status = CASE WHEN status='pending' THEN 'paid' ELSE 'pending' END,
                updated_at = now()
         WHERE  id <= ${UPDATE_ROWS};"

    # 每轮后采集一次死元组数
    if [[ "${DRY_RUN}" != "true" ]]; then
      local dead_now
      dead_now=$(sql "SELECT n_dead_tup FROM pg_stat_user_tables
                      WHERE schemaname='${SCHEMA}' AND relname='${TABLE}';")
      info "第 ${round} 轮后死元组数: ${dead_now}"
    fi
  done

  INJECTED=true
  info "死元组注入完成"
}

# ── Phase 5: 观测等待 ─────────────────────────────────────────────────────────
observe() {
  info "===== Phase 5: 进入观测模式 ====="
  info "故障已注入，等待 SRE 定位和恢复"
  info "按 Ctrl+C 退出 → 自动清理"
  info "每 ${OBSERVE_INTERVAL}s 采集一次指标"
  info "========================================="

  local tick=0
  while true; do
    tick=$((tick + 1))

    if [[ "${DRY_RUN}" != "true" ]]; then
      echo ""
      info "── 观测 #${tick} ──────────────────────────"

      # 死元组数
      local dead_tup
      dead_tup=$(sql "SELECT n_dead_tup FROM pg_stat_user_tables
                      WHERE schemaname='${SCHEMA}' AND relname='${TABLE}';")
      info "死元组: ${dead_tup}"

      # 表大小
      local tbl_size
      tbl_size=$(sql "SELECT pg_size_pretty(pg_total_relation_size('${SCHEMA}.${TABLE}'));")
      info "表大小: ${tbl_size}"

      # EXPLAIN cost
      local current_plan
      current_plan=$(sql "EXPLAIN SELECT count(*) FROM ${SCHEMA}.${TABLE}
                          WHERE status='pending' AND region='east'
                          GROUP BY user_id ORDER BY count(*) DESC LIMIT 10;" \
                     | head -1)
      info "当前 EXPLAIN: ${current_plan}"
      if [[ -n "${BASELINE_COST}" ]]; then
        info "基线 EXPLAIN: ${BASELINE_COST}"
      fi

      # 长事务状态
      local tx_state
      tx_state=$(sql "SELECT pid, state, now()-xact_start AS duration
                      FROM pg_stat_activity
                      WHERE application_name = 'fault_drill_long_tx';")
      info "长事务状态: ${tx_state}"

      # autovacuum 状态
      local av_state
      av_state=$(sql "SELECT pid, query, now()-query_start AS duration
                      FROM pg_stat_activity
                      WHERE query LIKE '%autovacuum%${TABLE}%';" 2>/dev/null)
      if [[ -n "${av_state}" ]]; then
        info "autovacuum: ${av_state}"
      else
        info "autovacuum: 未在运行 (被长事务阻塞)"
      fi
    else
      info "DRY-RUN: 观测 #${tick}"
    fi

    sleep "${OBSERVE_INTERVAL}"
  done
}

# ── 主流程 ────────────────────────────────────────────────────────────────────
main() {
  info "========================================="
  info "GaussDB 故障演练: 死元组积压"
  info "DRY_RUN=${DRY_RUN}"
  info "========================================="

  precheck
  setup_seed
  record_baseline
  start_long_transaction
  generate_dead_tuples
  observe
}

main "$@"
