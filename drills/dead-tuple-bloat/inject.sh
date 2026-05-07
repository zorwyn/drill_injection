#!/usr/bin/env bash
###############################################################################
# GaussDB 故障演练 — 死元组积压导致 SQL 整体变慢
#
# 故障链路: 长事务持有旧快照 → autovacuum 无法回收 → 死元组积压
#          → 表膨胀 → 优化器代价估算偏差 → 查询计划变差 → SQL 整体变慢
#
# 使用方式:
#   bash inject.sh                                          # demo 模式, 模拟输出看效果
#   DRY_RUN=false GSQL="gsql -d mydb -p 5432" bash inject.sh  # 实际注入
#
# 退出即清理 — Ctrl+C / kill / SSH 断开 都会自动回滚
# 单文件，scp 到服务器直接跑，无外部依赖
###############################################################################
set -uo pipefail

# ── 可调参数 (全部通过环境变量覆盖) ──────────────────────────────────────────
GSQL="${GSQL:-gsql -d postgres -p 5432}"       # 数据库连接命令
DRY_RUN="${DRY_RUN:-true}"                     # true=只打印不执行
SCHEMA="${SCHEMA:-fault_drill}"                # 演练用 schema (隔离)
TABLE="${TABLE:-drill_orders}"                 # 目标表名
SEED_ROWS="${SEED_ROWS:-500000}"               # 种子数据行数
UPDATE_ROWS="${UPDATE_ROWS:-200000}"           # 每轮更新行数
UPDATE_ROUNDS="${UPDATE_ROUNDS:-5}"            # UPDATE 轮次
OBSERVE_INTERVAL="${OBSERVE_INTERVAL:-30}"     # 观测采集间隔 (秒)
ABORT_CONN_PCT="${ABORT_CONN_PCT:-80}"         # 连接数超此比例则中止
ABORT_LAG_SEC="${ABORT_LAG_SEC:-60}"           # 复制延迟超此秒数则中止
DROP_ON_EXIT="${DROP_ON_EXIT:-false}"          # true=退出时删除演练 schema
WORKLOAD_INTERVAL="${WORKLOAD_INTERVAL:-3}"    # 模拟业务流量间隔 (秒)
WORKLOAD_CONCURRENCY="${WORKLOAD_CONCURRENCY:-4}"  # 模拟业务并发数

# ── 内部状态 ──────────────────────────────────────────────────────────────────
LONG_TX_PID=""
LONG_TX_BACKEND=""
INJECTED=false
SEED_CREATED=false
BASELINE_COST=""
BASELINE_DEAD=""
BASELINE_SIMPLE_MS=""                          # 简单查询基线耗时
BASELINE_AGG_MS=""                             # 聚合查询基线耗时
WORKLOAD_PIDS=()                               # 后台业务流量进程 PID

# ── 工具函数 ──────────────────────────────────────────────────────────────────
log()  { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
info() { log "INFO  $*"; }
warn() { log "WARN  $*"; }
err()  { log "ERROR $*"; }

sql() {
  if [[ "${DRY_RUN}" == "true" ]]; then
    log "DRY-RUN SQL: $(echo "$1" | head -1 | cut -c1-120)"
    return 0
  fi
  ${GSQL} -t -A -c "$1" 2>&1
}

sql_verbose() {
  if [[ "${DRY_RUN}" == "true" ]]; then
    log "DRY-RUN SQL: $(echo "$1" | head -1 | cut -c1-120)"
    return 0
  fi
  ${GSQL} -c "$1" 2>&1
}

# ── 清理函数 (trap EXIT — 任何退出都走这里) ──────────────────────────────────
cleanup() {
  local exit_code=$?
  echo ""
  info "╔═══════════════════════════════════════╗"
  info "║          自动清理开始                 ║"
  info "║  exit_code=${exit_code}                          ║"
  info "╚═══════════════════════════════════════╝"

  # 0) 杀后台业务流量进程
  if [[ ${#WORKLOAD_PIDS[@]} -gt 0 ]]; then
    info "[清理 0/5] 停止模拟业务流量 (${#WORKLOAD_PIDS[@]} 个进程)"
    for wpid in "${WORKLOAD_PIDS[@]}"; do
      kill "${wpid}" 2>/dev/null || true
    done
    for wpid in "${WORKLOAD_PIDS[@]}"; do
      wait "${wpid}" 2>/dev/null || true
    done
  fi

  # 1) 杀后台长事务 shell 进程
  if [[ -n "${LONG_TX_PID}" ]]; then
    info "[清理 1/5] 终止长事务 shell 进程 (pid=${LONG_TX_PID})"
    kill "${LONG_TX_PID}" 2>/dev/null || true
    wait "${LONG_TX_PID}" 2>/dev/null || true
  fi
  rm -f /tmp/fault_drill_long_tx_*.sql 2>/dev/null || true

  # 2) 数据库侧兜底: 按 application_name 杀所有演练会话
  if [[ "${DRY_RUN}" != "true" ]]; then
    info "[清理 2/5] pg_terminate_backend 清理演练会话"
    sql "SELECT pg_terminate_backend(pid)
         FROM pg_stat_activity
         WHERE application_name = 'fault_drill_long_tx'
           AND pid <> pg_backend_pid();" || true
  fi

  # 3) VACUUM 回收死元组
  if [[ "${INJECTED}" == "true" ]]; then
    info "[清理 3/5] VACUUM ANALYZE ${SCHEMA}.${TABLE}"
    sql "VACUUM ANALYZE ${SCHEMA}.${TABLE};" || true
  fi

  # 4) 可选: 删除演练 schema
  if [[ "${DROP_ON_EXIT}" == "true" ]] && [[ "${SEED_CREATED}" == "true" ]]; then
    info "[清理 4/5] DROP SCHEMA ${SCHEMA} CASCADE"
    sql "DROP SCHEMA IF EXISTS ${SCHEMA} CASCADE;" || true
  else
    info "[清理 4/5] 保留演练数据 (DROP_ON_EXIT=true 可自动删除)"
  fi

  # 5) 最终状态确认
  if [[ "${DRY_RUN}" != "true" ]] && [[ "${DROP_ON_EXIT}" != "true" ]]; then
    info "[清理 5/5] 清理后状态确认:"
    sql "SELECT
           n_dead_tup   AS dead_tuples,
           n_live_tup   AS live_tuples,
           pg_size_pretty(pg_total_relation_size('${SCHEMA}.${TABLE}')) AS table_size,
           last_autovacuum
         FROM pg_stat_user_tables
         WHERE schemaname='${SCHEMA}' AND relname='${TABLE}';" || true
  fi

  info "清理完成 ✓"
}

trap cleanup EXIT INT TERM HUP

# ── 中止条件检查 ──────────────────────────────────────────────────────────────
check_abort() {
  if [[ "${DRY_RUN}" == "true" ]]; then return 0; fi

  # 连接数
  local conn_pct
  conn_pct=$(sql "SELECT round(100.0 * count(*) /
                  current_setting('max_connections')::int)
                  FROM pg_stat_activity;" | tr -d ' ')
  if [[ -n "${conn_pct}" ]] && (( conn_pct > ABORT_CONN_PCT )); then
    err "ABORT: 连接数 ${conn_pct}% 超过阈值 ${ABORT_CONN_PCT}%"
    return 1
  fi

  # 复制延迟
  local lag
  lag=$(sql "SELECT coalesce(max(extract(epoch FROM replay_lag)), 0)
             FROM pg_stat_replication;" | tr -d ' ')
  if [[ -n "${lag}" ]]; then
    local lag_over
    lag_over=$(echo "${lag} > ${ABORT_LAG_SEC}" | bc -l 2>/dev/null || echo 0)
    if (( lag_over )); then
      err "ABORT: 复制延迟 ${lag}s 超过阈值 ${ABORT_LAG_SEC}s"
      return 1
    fi
  fi

  return 0
}

###############################################################################
#                              各阶段实现
###############################################################################

# ── Phase 0: 前置检查 ────────────────────────────────────────────────────────
phase_precheck() {
  info "===== Phase 0: 前置检查 ====="

  if [[ "${DRY_RUN}" != "true" ]]; then
    sql "SELECT 1;" >/dev/null || { err "无法连接数据库"; exit 1; }
    info "数据库连接 ✓"

    local long_tx_count
    long_tx_count=$(sql "SELECT count(*) FROM pg_stat_activity
                         WHERE state = 'idle in transaction'
                           AND now() - xact_start > interval '5 minutes';")
    if [[ "${long_tx_count}" -gt 0 ]]; then
      warn "已存在 ${long_tx_count} 个长事务，可能影响演练结果"
    fi

    check_abort || { err "前置检查未通过中止条件"; exit 1; }
  fi

  info "前置检查通过 ✓"
}

# ── Phase 1: 创建种子数据 ────────────────────────────────────────────────────
phase_seed() {
  info "===== Phase 1: 创建种子数据 (${SEED_ROWS} 行) ====="

  # GaussDB 不支持 CREATE SCHEMA IF NOT EXISTS, 先判断再建
  local schema_exists
  schema_exists=$(sql "SELECT count(*) FROM pg_namespace WHERE nspname='${SCHEMA}'")
  if [[ "${schema_exists}" == "0" ]] || [[ "${DRY_RUN}" == "true" ]]; then
    sql "CREATE SCHEMA ${SCHEMA};"
  fi
  sql "DROP TABLE IF EXISTS ${SCHEMA}.${TABLE};"

  # 必须用 ASTORE — ustore 原地更新不产生死元组, 演练无效
  sql "CREATE TABLE ${SCHEMA}.${TABLE} (
         id         BIGSERIAL      PRIMARY KEY,
         user_id    INT            NOT NULL,
         amount     NUMERIC(12,2)  NOT NULL,
         status     VARCHAR(20)    NOT NULL DEFAULT 'pending',
         region     VARCHAR(10)    NOT NULL,
         created_at TIMESTAMP      NOT NULL DEFAULT now(),
         updated_at TIMESTAMP      NOT NULL DEFAULT now(),
         padding    VARCHAR(200)   NOT NULL DEFAULT repeat('x', 200)
       ) WITH (STORAGE_TYPE=ASTORE);"

  sql "CREATE INDEX idx_drill_status ON ${SCHEMA}.${TABLE}(status);"
  sql "CREATE INDEX idx_drill_user   ON ${SCHEMA}.${TABLE}(user_id);"
  sql "CREATE INDEX idx_drill_region ON ${SCHEMA}.${TABLE}(region);"

  sql "INSERT INTO ${SCHEMA}.${TABLE} (user_id, amount, status, region)
       SELECT
         (random()*10000)::INT,
         (random()*9999+1)::NUMERIC(12,2),
         (ARRAY['pending','paid','shipped','done','cancelled'])
           [floor(random()*5+1)::INT],
         (ARRAY['east','west','north','south','central'])
           [floor(random()*5+1)::INT]
       FROM generate_series(1, ${SEED_ROWS});"

  sql "ANALYZE ${SCHEMA}.${TABLE};"

  SEED_CREATED=true
  info "种子数据就绪 ✓"
}

# ── Phase 2: 记录基线 ────────────────────────────────────────────────────────
phase_baseline() {
  info "===== Phase 2: 记录基线 ====="

  if [[ "${DRY_RUN}" != "true" ]]; then
    BASELINE_DEAD=$(sql "SELECT n_dead_tup FROM pg_stat_user_tables
                         WHERE schemaname='${SCHEMA}' AND relname='${TABLE}';")
    info "基线死元组: ${BASELINE_DEAD}"

    local tbl_size
    tbl_size=$(sql "SELECT pg_size_pretty(pg_total_relation_size(
                    '${SCHEMA}.${TABLE}'));")
    info "基线表大小: ${tbl_size}"

    BASELINE_COST=$(sql "EXPLAIN SELECT count(*) FROM ${SCHEMA}.${TABLE}
                         WHERE status='pending' AND region='east'
                         GROUP BY user_id ORDER BY count(*) DESC LIMIT 10;" \
                    | head -1)
    info "基线 EXPLAIN: ${BASELINE_COST}"

    # 简单查询基线耗时 (主键点查)
    BASELINE_SIMPLE_MS=$(sql "EXPLAIN ANALYZE SELECT * FROM ${SCHEMA}.${TABLE} WHERE id = 1;" \
                         | grep 'Execution Time' | grep -oE '[0-9]+\.[0-9]+')
    info "基线简单查询 (点查 id=1): ${BASELINE_SIMPLE_MS} ms"

    # 聚合查询基线耗时
    BASELINE_AGG_MS=$(sql "EXPLAIN ANALYZE
                           SELECT region, count(*), avg(amount)
                           FROM ${SCHEMA}.${TABLE}
                           WHERE status = 'pending'
                           GROUP BY region;" \
                     | grep 'Execution Time' | grep -oE '[0-9]+\.[0-9]+')
    info "基线聚合查询 (GROUP BY): ${BASELINE_AGG_MS} ms"

    # 完整 EXPLAIN ANALYZE 留底
    info "基线详细计划:"
    sql_verbose "EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
                 SELECT region, count(*), avg(amount)
                 FROM ${SCHEMA}.${TABLE}
                 WHERE status = 'pending'
                 GROUP BY region;"
  else
    info "DRY-RUN: 跳过基线采集"
  fi

  info "基线记录完成 ✓"
}

# ── Phase 3: 注入长事务 ──────────────────────────────────────────────────────
phase_long_tx() {
  info "===== Phase 3: 注入长事务 (pin snapshot) ====="

  if [[ "${DRY_RUN}" == "true" ]]; then
    log "DRY-RUN: 将开启长事务, 执行 SELECT 固定快照, 阻止 autovacuum 回收"
    return 0
  fi

  # 后台开事务: 写临时 SQL 文件, gsql -f 执行确保单连接内顺序执行
  # 用 REPEATABLE READ 强制 pin 住快照, 阻止 autovacuum 回收
  local tx_sql_file="/tmp/fault_drill_long_tx_$$.sql"
  cat > "${tx_sql_file}" <<EOF
SET application_name = 'fault_drill_long_tx';
START TRANSACTION ISOLATION LEVEL REPEATABLE READ;
SELECT count(*) FROM ${SCHEMA}.${TABLE} WHERE status = 'pending';
SELECT pg_sleep(86400);
COMMIT;
EOF
  (
    ${GSQL} -f "${tx_sql_file}"
    rm -f "${tx_sql_file}"
  ) &
  LONG_TX_PID=$!
  sleep 5

  # pg_sleep 是阻塞调用, 事务状态是 active 不是 idle in transaction
  LONG_TX_BACKEND=$(sql "SELECT pid FROM pg_stat_activity
                         WHERE application_name = 'fault_drill_long_tx'
                         ORDER BY xact_start LIMIT 1")

  if [[ -z "${LONG_TX_BACKEND}" ]]; then
    warn "未找到长事务 backend, 可能启动延迟, 重试..."
    sleep 3
    LONG_TX_BACKEND=$(sql "SELECT pid FROM pg_stat_activity
                           WHERE application_name = 'fault_drill_long_tx'
                           ORDER BY xact_start LIMIT 1")
  fi

  info "长事务已启动 (shell_pid=${LONG_TX_PID}, backend_pid=${LONG_TX_BACKEND})"

  # 确认长事务会话状态
  sql "SELECT pid, state, xact_start, now() - xact_start AS tx_duration
       FROM pg_stat_activity
       WHERE pid = ${LONG_TX_BACKEND};"
  info "长事务注入完成 ✓"
}

# ── Phase 4: 批量 UPDATE 制造死元组 ──────────────────────────────────────────
phase_dead_tuples() {
  info "===== Phase 4: 制造死元组 (${UPDATE_ROUNDS} 轮 x ${UPDATE_ROWS} 行) ====="

  # 每轮更新不同字段, 模拟真实业务多样性
  local round_sqls=(
    "UPDATE ${SCHEMA}.${TABLE}
     SET status = CASE WHEN status='pending' THEN 'paid' ELSE 'pending' END,
         updated_at = now()
     WHERE id <= ${UPDATE_ROWS};"

    "UPDATE ${SCHEMA}.${TABLE}
     SET amount = amount + 0.01,
         updated_at = now()
     WHERE id <= ${UPDATE_ROWS};"

    "UPDATE ${SCHEMA}.${TABLE}
     SET region = CASE WHEN region LIKE 'drill_%' THEN substr(region,7)
                       ELSE 'drill_' || region END,
         updated_at = now()
     WHERE id <= ${UPDATE_ROWS};"

    "UPDATE ${SCHEMA}.${TABLE}
     SET status = 'review',
         updated_at = now()
     WHERE id IN (SELECT id FROM ${SCHEMA}.${TABLE} ORDER BY id LIMIT ${UPDATE_ROWS});"

    "UPDATE ${SCHEMA}.${TABLE}
     SET amount = amount - 0.01,
         status = CASE WHEN status='review' THEN 'done' ELSE status END,
         updated_at = now()
     WHERE id <= ${UPDATE_ROWS};"
  )

  for round in $(seq 1 "${UPDATE_ROUNDS}"); do
    # 中止条件检查
    check_abort || { warn "触发中止条件, 停止注入"; break; }

    local idx=$(( (round - 1) % ${#round_sqls[@]} ))
    info "第 ${round}/${UPDATE_ROUNDS} 轮 UPDATE (变更模式 $((idx+1)))..."
    sql "${round_sqls[$idx]}"

    if [[ "${DRY_RUN}" != "true" ]]; then
      local dead_now live_now
      dead_now=$(sql "SELECT n_dead_tup FROM pg_stat_user_tables
                      WHERE schemaname='${SCHEMA}' AND relname='${TABLE}';")
      live_now=$(sql "SELECT n_live_tup FROM pg_stat_user_tables
                      WHERE schemaname='${SCHEMA}' AND relname='${TABLE}';")
      info "第 ${round} 轮后 → 死元组: ${dead_now} | 活元组: ${live_now}"
    fi
  done

  INJECTED=true
  info "死元组注入完成 ✓"
}

# ── Phase 5: 验证故障效果 ────────────────────────────────────────────────────
phase_verify() {
  info "===== Phase 5: 验证故障效果 ====="

  if [[ "${DRY_RUN}" == "true" ]]; then
    info "[demo] 死元组: 1000000 | 活元组: 500000 | 死元组比: 66.7%"
    info "[demo] 表大小: 380 MB (基线 210 MB)"
    info "[demo] EXPLAIN cost: 基线 12840 → 当前 38520 (3.0x)"
    info "[demo] autovacuum: 被长事务阻塞, 无法运行"
    return 0
  fi

  # 表统计
  info "── 表膨胀统计 ──"
  sql_verbose "SELECT
      n_live_tup,
      n_dead_tup,
      round(n_dead_tup::numeric / NULLIF(n_live_tup + n_dead_tup, 0) * 100, 1)
        AS dead_ratio_pct,
      pg_size_pretty(pg_total_relation_size('${SCHEMA}.${TABLE}'))
        AS total_size,
      last_autovacuum,
      last_autoanalyze
    FROM pg_stat_user_tables
    WHERE schemaname = '${SCHEMA}' AND relname = '${TABLE}';"

  # 查询计划退化对比
  info "── 查询计划对比 (vs 基线) ──"
  info "基线: ${BASELINE_COST}"
  local current_cost
  current_cost=$(sql "EXPLAIN SELECT count(*) FROM ${SCHEMA}.${TABLE}
                      WHERE status='pending' AND region='east'
                      GROUP BY user_id ORDER BY count(*) DESC LIMIT 10;" \
                 | head -1)
  info "当前: ${current_cost}"

  # 典型查询 EXPLAIN ANALYZE
  info "── 聚合查询计划 ──"
  sql_verbose "EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
    SELECT region, count(*), avg(amount)
    FROM ${SCHEMA}.${TABLE}
    WHERE status = 'pending'
    GROUP BY region;"

  info "── 索引选择性查询计划 ──"
  sql_verbose "EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
    SELECT *
    FROM ${SCHEMA}.${TABLE}
    WHERE user_id = 42 AND status = 'paid'
    ORDER BY created_at DESC
    LIMIT 20;"

  info "── 自连接查询计划 ──"
  sql_verbose "EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
    SELECT a.id, a.amount, b.amount
    FROM ${SCHEMA}.${TABLE} a
    JOIN ${SCHEMA}.${TABLE} b ON a.user_id = b.user_id
    WHERE a.status = 'shipped' AND b.status = 'done'
    LIMIT 100;"

  # autovacuum 阻塞确认
  info "── autovacuum 阻塞状态 ──"
  sql_verbose "SELECT pid, state, xact_start,
      now() - query_start AS duration,
      application_name, left(query, 80) AS query
    FROM pg_stat_activity
    WHERE application_name = 'fault_drill_long_tx'
       OR query LIKE '%autovacuum%${TABLE}%';"

  info "故障验证完成 ✓"
}

# ── 模拟业务流量 (单个 worker) ────────────────────────────────────────────────
# 后台持续跑业务 SQL, 打印耗时, 模拟真实应用流量
# SRE 看到这些查询越来越慢 → 触发排查
workload_worker() {
  local worker_id=$1
  local schema=$2
  local table=$3
  local interval=$4
  local gsql_cmd=$5

  # 模拟 5 种典型业务查询
  local queries=(
    "SELECT * FROM ${schema}.${table} WHERE id = (random()*500000)::int + 1;"
    "SELECT count(*), avg(amount) FROM ${schema}.${table} WHERE status='pending' AND region='east';"
    "SELECT user_id, sum(amount) FROM ${schema}.${table} WHERE status IN ('pending','paid') GROUP BY user_id ORDER BY sum(amount) DESC LIMIT 20;"
    "SELECT * FROM ${schema}.${table} WHERE user_id = (random()*10000)::int AND status = 'paid' ORDER BY created_at DESC LIMIT 10;"
    "SELECT region, status, count(*), avg(amount) FROM ${schema}.${table} GROUP BY region, status ORDER BY count(*) DESC;"
  )
  local query_names=(
    "点查"
    "条件聚合"
    "TOP-N"
    "用户订单"
    "多维汇总"
  )

  while true; do
    local idx=$(( RANDOM % ${#queries[@]} ))
    local qname="${query_names[$idx]}"

    # 用 \timing 拿真实耗时
    local start_ns=$(date +%s%N 2>/dev/null || date +%s)
    ${gsql_cmd} -t -A -c "${queries[$idx]}" >/dev/null 2>&1
    local end_ns=$(date +%s%N 2>/dev/null || date +%s)

    local elapsed_ms
    if [[ ${#start_ns} -gt 10 ]]; then
      # 有纳秒精度
      elapsed_ms=$(( (end_ns - start_ns) / 1000000 ))
    else
      # 只有秒精度, 降级
      elapsed_ms=$(( (end_ns - start_ns) * 1000 ))
    fi

    # 超过 200ms 标红, 超过 1000ms 标告警
    local tag=""
    if [[ ${elapsed_ms} -ge 1000 ]]; then
      tag=" !! SLOW !!"
    elif [[ ${elapsed_ms} -ge 200 ]]; then
      tag=" * slow"
    fi

    printf '[%s] WORKLOAD[%d] %-10s %6d ms%s\n' \
      "$(date '+%F %T')" "${worker_id}" "${qname}" "${elapsed_ms}" "${tag}"

    sleep "${interval}"
  done
}

# ── Demo 模式 workload worker (不连库, 随机数模拟退化) ────────────────────────
demo_workload_worker() {
  local worker_id=$1
  local interval=$2

  local query_names=("点查" "条件聚合" "TOP-N" "用户订单" "多维汇总")
  # 每种查询的基线耗时 (ms)
  local base_times=(3 45 62 8 89)
  local tick=0

  while true; do
    tick=$((tick + 1))
    local idx=$(( RANDOM % ${#query_names[@]} ))
    local qname="${query_names[$idx]}"
    local base=${base_times[$idx]}

    # 模拟逐渐变慢: 每轮 tick 增加一个倍率, 加一些随机抖动
    local multiplier=$(( 1 + tick / 5 ))
    local jitter=$(( RANDOM % (base / 2 + 1) ))
    local elapsed_ms=$(( base * multiplier + jitter ))

    local tag=""
    if [[ ${elapsed_ms} -ge 1000 ]]; then
      tag=" !! SLOW !!"
    elif [[ ${elapsed_ms} -ge 200 ]]; then
      tag=" * slow"
    fi

    printf '[%s] WORKLOAD[%d] %-10s %6d ms%s\n' \
      "$(date '+%F %T')" "${worker_id}" "${qname}" "${elapsed_ms}" "${tag}"

    sleep "${interval}"
  done
}

# ── Phase 6: 启动模拟业务流量 ────────────────────────────────────────────────
phase_workload() {
  info "===== Phase 6: 启动模拟业务流量 ====="

  if [[ "${DRY_RUN}" == "true" ]]; then
    info "DRY_RUN=true → 启动 demo 模式 (模拟数据, 不连库)"
    for i in $(seq 1 "${WORKLOAD_CONCURRENCY}"); do
      demo_workload_worker "${i}" "${WORKLOAD_INTERVAL}" &
      WORKLOAD_PIDS+=($!)
    done
    info "Demo 业务流量已启动 (${WORKLOAD_CONCURRENCY} 并发)"
    return 0
  fi

  for i in $(seq 1 "${WORKLOAD_CONCURRENCY}"); do
    workload_worker "${i}" "${SCHEMA}" "${TABLE}" "${WORKLOAD_INTERVAL}" "${GSQL}" &
    WORKLOAD_PIDS+=($!)
    info "业务流量 worker ${i} 已启动 (pid=${WORKLOAD_PIDS[-1]})"
  done

  info "模拟业务流量启动完成 (${WORKLOAD_CONCURRENCY} 并发, 间隔 ${WORKLOAD_INTERVAL}s) ✓"
}

# ── Phase 7: 观测等待 (SRE 定位时间) ─────────────────────────────────────────
phase_observe() {
  info "╔═══════════════════════════════════════════════════╗"
  info "║  故障已注入, 业务流量运行中                       ║"
  info "║                                                   ║"
  info "║  SRE 应该能观察到:                                ║"
  info "║    1. WORKLOAD 日志中查询耗时逐渐升高             ║"
  info "║    2. 部分查询出现 * slow 或 !! SLOW !! 标记      ║"
  info "║                                                   ║"
  info "║  SRE 需要:                                        ║"
  info "║    - 自己开一个 gsql 去排查                       ║"
  info "║    - 找到根因 (长事务 → 死元组)                   ║"
  info "║    - 手动恢复 (kill 长事务 + VACUUM)              ║"
  info "║                                                   ║"
  info "║  演练出题人: Ctrl+C 退出 → 自动清理               ║"
  info "╚═══════════════════════════════════════════════════╝"

  local tick=0
  while true; do
    tick=$((tick + 1))

    if [[ "${DRY_RUN}" != "true" ]]; then
      # 每隔 OBSERVE_INTERVAL 做一轮后台指标采集 (不干扰 workload 输出)
      # 只在关键节点打日志, 不刷屏
      if (( tick % 4 == 0 )); then
        echo ""
        info "── 后台指标 #${tick} ──"
        local dead_tup tx_alive

        dead_tup=$(sql "SELECT n_dead_tup FROM pg_stat_user_tables
                        WHERE schemaname='${SCHEMA}' AND relname='${TABLE}';")
        tx_alive=$(sql "SELECT count(*) FROM pg_stat_activity
                        WHERE application_name = 'fault_drill_long_tx'")

        info "死元组: ${dead_tup} | 长事务存活: ${tx_alive}"

        # 检测 SRE 是否已恢复
        if [[ "${dead_tup}" -lt 1000 ]] && [[ "${tx_alive}" == "0" ]]; then
          echo ""
          info "╔═══════════════════════════════════════╗"
          info "║  SRE 演练完成!                        ║"
          info "║  长事务已终止, 死元组已回收            ║"
          info "╚═══════════════════════════════════════╝"
          info "等待 30s 确认业务流量恢复正常..."
          sleep 30
          return 0
        fi
      fi

      # 中止条件
      check_abort || { warn "触发中止条件, 退出"; return 1; }
    else
      # DRY-RUN demo: 模拟后台指标
      if (( tick % 4 == 0 )); then
        local sim_dead=$(( 200000 * tick / 4 ))
        echo ""
        info "── [demo] 后台指标 #${tick} ──"
        info "死元组: ${sim_dead} | 长事务存活: 1"
      fi
    fi

    sleep "${OBSERVE_INTERVAL}"
  done
}

###############################################################################
#                              主入口
###############################################################################
main() {
  info "╔═══════════════════════════════════════╗"
  info "║  GaussDB 故障演练: 死元组积压         ║"
  info "╠═══════════════════════════════════════╣"
  info "║  DRY_RUN=${DRY_RUN}                          ║"
  info "║  DB=${GSQL}  ║"
  info "║  种子: ${SEED_ROWS} 行                     ║"
  info "║  更新: ${UPDATE_ROUNDS} 轮 x ${UPDATE_ROWS} 行             ║"
  info "╚═══════════════════════════════════════╝"

  phase_precheck
  phase_seed
  phase_baseline
  phase_long_tx
  phase_dead_tuples
  phase_verify
  phase_workload       # 启动模拟业务流量
  phase_observe        # 等 SRE 定位恢复
}

main "$@"
