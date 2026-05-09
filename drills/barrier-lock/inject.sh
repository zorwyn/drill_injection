#!/usr/bin/env bash
###############################################################################
# GaussDB 故障演练 — 备份卡住导致 BarrierLock 等待
#
# 故障链路: 备份任务 pg_start_backup 卡住不释放
#          → 持有 BarrierLock / ExclusiveBackupLock
#          → 后续 DDL / checkpoint / 备份操作排队等锁
#          → 业务 SQL 被间接阻塞, 响应时间飙升
#
# 使用方式:
#   bash inject.sh                                             # demo 模式
#   DRY_RUN=false GSQL="gsql -d mydb -p 5432" bash inject.sh  # 实际注入
#
# 退出即清理 — Ctrl+C / kill / SSH 断开 都会自动回滚
# 单文件, scp 到服务器直接跑, 无外部依赖
###############################################################################
set -uo pipefail

# ── 可调参数 ─────────────────────────────────────────────────────────────────
GSQL="${GSQL:-gsql -d postgres -p 5432}"
DRY_RUN="${DRY_RUN:-true}"
SCHEMA="${SCHEMA:-fault_drill}"
TABLE="${TABLE:-drill_txns}"
SEED_ROWS="${SEED_ROWS:-500000}"
OBSERVE_INTERVAL="${OBSERVE_INTERVAL:-15}"
WORKLOAD_INTERVAL="${WORKLOAD_INTERVAL:-2}"
WORKLOAD_CONCURRENCY="${WORKLOAD_CONCURRENCY:-4}"
DDL_INTERVAL="${DDL_INTERVAL:-5}"              # DDL 冲突制造间隔 (秒)
DDL_CONCURRENCY="${DDL_CONCURRENCY:-3}"        # DDL 并发数
ABORT_CONN_PCT="${ABORT_CONN_PCT:-80}"
DROP_ON_EXIT="${DROP_ON_EXIT:-false}"

# ── 标准查询 ─────────────────────────────────────────────────────────────────
QUERY_NAMES=("点查" "范围查" "聚合" "排序" "子查询")

get_query() {
  case $1 in
    0) echo "SELECT * FROM ${SCHEMA}.${TABLE} WHERE id = 1" ;;
    1) echo "SELECT * FROM ${SCHEMA}.${TABLE} WHERE amount > 5000 AND region = 'east' LIMIT 50" ;;
    2) echo "SELECT region, count(*), sum(amount) FROM ${SCHEMA}.${TABLE} GROUP BY region" ;;
    3) echo "SELECT * FROM ${SCHEMA}.${TABLE} ORDER BY created_at DESC LIMIT 100" ;;
    4) echo "SELECT * FROM ${SCHEMA}.${TABLE} WHERE user_id IN (SELECT user_id FROM ${SCHEMA}.${TABLE} WHERE status='pending' LIMIT 10)" ;;
  esac
}

# ── 内部状态 ──────────────────────────────────────────────────────────────────
BACKUP_PID=""                                  # 后台备份会话的 shell PID
BACKUP_BACKEND=""                              # 备份会话的 gaussdb backend pid
SEED_CREATED=false
BASELINE_FILE="/tmp/fault_drill_barrier_baseline_$$.dat"
BASELINE_PLAN_DIR="/tmp/fault_drill_barrier_plans_$$"
WORKLOAD_PIDS=()
DDL_PIDS=()

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

bench_ms() {
  local start_ns end_ns elapsed
  start_ns=$(date +%s%N 2>/dev/null || date +%s)
  ${GSQL} -t -A -c "$1" >/dev/null 2>&1
  end_ns=$(date +%s%N 2>/dev/null || date +%s)
  if [[ ${#start_ns} -gt 10 ]]; then
    elapsed=$(( (end_ns - start_ns) / 1000000 ))
  else
    elapsed=$(( (end_ns - start_ns) * 1000 ))
  fi
  echo "${elapsed}"
}

# ── 清理 (trap EXIT) ────────────────────────────────────────────────────────
cleanup() {
  local exit_code=$?
  echo ""
  info "╔═══════════════════════════════════════╗"
  info "║          自动清理开始                 ║"
  info "╚═══════════════════════════════════════╝"

  # 0) 停 workload
  if [[ ${#WORKLOAD_PIDS[@]} -gt 0 ]]; then
    info "[清理 1/5] 停止业务流量 (${#WORKLOAD_PIDS[@]} 进程)"
    for pid in "${WORKLOAD_PIDS[@]}"; do kill "${pid}" 2>/dev/null || true; done
    for pid in "${WORKLOAD_PIDS[@]}"; do wait "${pid}" 2>/dev/null || true; done
  fi

  # 1) 停 DDL 冲突进程
  if [[ ${#DDL_PIDS[@]} -gt 0 ]]; then
    info "[清理 2/5] 停止 DDL 冲突进程 (${#DDL_PIDS[@]} 进程)"
    for pid in "${DDL_PIDS[@]}"; do kill "${pid}" 2>/dev/null || true; done
    for pid in "${DDL_PIDS[@]}"; do wait "${pid}" 2>/dev/null || true; done
  fi

  # 2) 杀备份会话
  if [[ -n "${BACKUP_PID}" ]]; then
    info "[清理 3/5] 终止备份 shell 进程 (pid=${BACKUP_PID})"
    kill "${BACKUP_PID}" 2>/dev/null || true
    wait "${BACKUP_PID}" 2>/dev/null || true
  fi

  # 3) 数据库侧: 停止备份 + 杀残留会话
  if [[ "${DRY_RUN}" != "true" ]]; then
    info "[清理 4/5] 数据库侧清理"
    # 停止备份状态
    sql "SELECT pg_stop_backup();" 2>/dev/null || true
    # 杀所有演练会话
    sql "SELECT pg_terminate_backend(pid)
         FROM pg_stat_activity
         WHERE application_name IN ('fault_drill_backup', 'fault_drill_ddl')
           AND pid <> pg_backend_pid();" || true
  fi

  # 4) 可选: 删除演练数据
  if [[ "${DROP_ON_EXIT}" == "true" ]] && [[ "${SEED_CREATED}" == "true" ]]; then
    info "[清理 5/5] DROP SCHEMA ${SCHEMA} CASCADE"
    sql "DROP SCHEMA IF EXISTS ${SCHEMA} CASCADE;" || true
  else
    info "[清理 5/5] 保留演练数据 (DROP_ON_EXIT=true 可删除)"
  fi

  rm -f /tmp/fault_drill_barrier_*.dat /tmp/fault_drill_backup_*.sql 2>/dev/null || true
  rm -rf /tmp/fault_drill_barrier_plans_* 2>/dev/null || true

  info "清理完成 ✓"
}

trap cleanup EXIT INT TERM HUP

# ── 中止条件 ──────────────────────────────────────────────────────────────────
check_abort() {
  if [[ "${DRY_RUN}" == "true" ]]; then return 0; fi
  local conn_pct
  conn_pct=$(sql "SELECT round(100.0 * count(*) /
                  current_setting('max_connections')::int)
                  FROM pg_stat_activity;" | tr -d ' ')
  if [[ -n "${conn_pct}" ]] && (( conn_pct > ABORT_CONN_PCT )); then
    err "ABORT: 连接数 ${conn_pct}% 超过阈值"
    return 1
  fi
  return 0
}

###############################################################################
#                              各阶段
###############################################################################

# ── Phase 0: 前置检查 ────────────────────────────────────────────────────────
phase_precheck() {
  info "===== Phase 0: 前置检查 ====="

  if [[ "${DRY_RUN}" != "true" ]]; then
    sql "SELECT 1" >/dev/null || { err "无法连接数据库"; exit 1; }
    info "数据库连接 ✓"

    # 检查是否已有备份在跑
    local backup_in_progress
    backup_in_progress=$(sql "SELECT pg_is_in_backup();" 2>/dev/null || echo "")
    if [[ "${backup_in_progress}" == "t" ]]; then
      err "数据库已有备份在进行中, 请先处理后再演练"
      exit 1
    fi
    info "无进行中的备份 ✓"

    check_abort || { err "中止条件未通过"; exit 1; }
  fi

  info "前置检查通过 ✓"
}

# ── Phase 1: 种子数据 ────────────────────────────────────────────────────────
phase_seed() {
  info "===== Phase 1: 创建种子数据 (${SEED_ROWS} 行) ====="

  local schema_exists
  schema_exists=$(sql "SELECT count(*) FROM pg_namespace WHERE nspname='${SCHEMA}'")
  if [[ "${schema_exists}" == "0" ]] || [[ "${DRY_RUN}" == "true" ]]; then
    sql "CREATE SCHEMA ${SCHEMA};"
  fi
  sql "DROP TABLE IF EXISTS ${SCHEMA}.${TABLE};"

  sql "CREATE TABLE ${SCHEMA}.${TABLE} (
         id         BIGSERIAL      PRIMARY KEY,
         user_id    INT            NOT NULL,
         amount     NUMERIC(12,2)  NOT NULL,
         status     VARCHAR(20)    NOT NULL DEFAULT 'pending',
         region     VARCHAR(10)    NOT NULL,
         created_at TIMESTAMP      NOT NULL DEFAULT now(),
         updated_at TIMESTAMP      NOT NULL DEFAULT now()
       ) WITH (STORAGE_TYPE=ASTORE);"

  sql "CREATE INDEX idx_barrier_status ON ${SCHEMA}.${TABLE}(status);"
  sql "CREATE INDEX idx_barrier_user   ON ${SCHEMA}.${TABLE}(user_id);"
  sql "CREATE INDEX idx_barrier_region ON ${SCHEMA}.${TABLE}(region);"

  # 用于 DDL 冲突的辅助表
  sql "CREATE TABLE ${SCHEMA}.drill_config (
         k VARCHAR(50) PRIMARY KEY,
         v VARCHAR(200)
       ) WITH (STORAGE_TYPE=ASTORE);"
  sql "INSERT INTO ${SCHEMA}.drill_config VALUES ('version', '1.0');"

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

# ── Phase 2: 基线 ────────────────────────────────────────────────────────────
phase_baseline() {
  info "===== Phase 2: 记录基线 ====="

  if [[ "${DRY_RUN}" != "true" ]]; then
    mkdir -p "${BASELINE_PLAN_DIR}"
    > "${BASELINE_FILE}"

    info "┌──────────────────────────────────────────────────┐"
    info "│         基线采集 (耗时 + EXPLAIN 计划)           │"
    for i in 0 1 2 3 4; do
      local q ms
      q=$(get_query $i)
      ms=$(bench_ms "${q}")
      echo "${ms}" >> "${BASELINE_FILE}"
      sql_verbose "EXPLAIN ANALYZE ${q}" > "${BASELINE_PLAN_DIR}/${i}.txt" 2>&1
      info "│ ${QUERY_NAMES[$i]}:  ${ms} ms"
    done
    info "└──────────────────────────────────────────────────┘"
  else
    info "DRY-RUN: 跳过基线"
  fi

  info "基线记录完成 ✓"
}

# ── Phase 3: 注入 — 卡住备份 ─────────────────────────────────────────────────
phase_inject_backup() {
  info "===== Phase 3: 注入卡住的备份任务 ====="

  if [[ "${DRY_RUN}" == "true" ]]; then
    info "DRY-RUN: 将调用 pg_start_backup 并 hold 住, 模拟备份卡死"
    return 0
  fi

  # 后台会话: 开始备份但永不结束
  local backup_sql="/tmp/fault_drill_backup_$$.sql"
  cat > "${backup_sql}" <<EOF
SET application_name = 'fault_drill_backup';
SELECT pg_start_backup('fault_drill_stuck_backup', true);
SELECT pg_sleep(86400);
SELECT pg_stop_backup();
EOF

  (
    ${GSQL} -f "${backup_sql}"
    rm -f "${backup_sql}"
  ) &
  BACKUP_PID=$!
  sleep 5

  # 找到 backend pid
  BACKUP_BACKEND=$(sql "SELECT pid FROM pg_stat_activity
                        WHERE application_name = 'fault_drill_backup'
                        ORDER BY xact_start LIMIT 1")

  if [[ -z "${BACKUP_BACKEND}" ]]; then
    warn "未找到备份 backend, 重试..."
    sleep 5
    BACKUP_BACKEND=$(sql "SELECT pid FROM pg_stat_activity
                          WHERE application_name = 'fault_drill_backup'
                          ORDER BY xact_start LIMIT 1")
  fi

  info "备份任务已卡住 (shell_pid=${BACKUP_PID}, backend_pid=${BACKUP_BACKEND})"

  # 确认备份状态
  local in_backup
  in_backup=$(sql "SELECT pg_is_in_backup();" 2>/dev/null || echo "unknown")
  info "pg_is_in_backup(): ${in_backup}"

  sql "SELECT pid, state, application_name,
       now() - xact_start AS duration, left(query, 60) AS query
       FROM pg_stat_activity WHERE pid = ${BACKUP_BACKEND}"

  info "备份注入完成 ✓"
}

# ── Phase 4: DDL 冲突制造器 ──────────────────────────────────────────────────
# 持续发起会跟备份锁冲突的操作, 制造 BarrierLock 等待
ddl_conflict_worker() {
  local worker_id=$1
  local schema=$2
  local interval=$3
  local gsql_cmd=$4

  # 会跟备份锁/BarrierLock 冲突的操作
  local ddl_ops=(
    "CHECKPOINT"
    "ALTER TABLE ${schema}.drill_config SET (fillfactor = $((60 + RANDOM % 40)))"
    "REINDEX INDEX ${schema}.idx_barrier_status"
    "ANALYZE ${schema}.drill_config"
    "VACUUM ${schema}.drill_config"
  )
  local ddl_names=(
    "CHECKPOINT"
    "ALTER TABLE"
    "REINDEX"
    "ANALYZE"
    "VACUUM"
  )

  while true; do
    local idx=$(( RANDOM % ${#ddl_ops[@]} ))
    local op_name="${ddl_names[$idx]}"

    local start_ns end_ns elapsed_ms
    start_ns=$(date +%s%N 2>/dev/null || date +%s)
    ${gsql_cmd} -c "SET application_name = 'fault_drill_ddl'; ${ddl_ops[$idx]};" >/dev/null 2>&1
    end_ns=$(date +%s%N 2>/dev/null || date +%s)

    if [[ ${#start_ns} -gt 10 ]]; then
      elapsed_ms=$(( (end_ns - start_ns) / 1000000 ))
    else
      elapsed_ms=$(( (end_ns - start_ns) * 1000 ))
    fi

    local tag=""
    if [[ ${elapsed_ms} -ge 5000 ]]; then
      tag=" !! BLOCKED !!"
    elif [[ ${elapsed_ms} -ge 1000 ]]; then
      tag=" * waiting"
    fi

    printf '[%s] DDL[%d] %-14s %6d ms%s\n' \
      "$(date '+%F %T')" "${worker_id}" "${op_name}" "${elapsed_ms}" "${tag}"

    sleep "${interval}"
  done
}

# ── 业务 workload ────────────────────────────────────────────────────────────
workload_worker() {
  local worker_id=$1
  local interval=$2
  local gsql_cmd=$3
  local baseline_file=$4

  local baselines=()
  if [[ -f "${baseline_file}" ]]; then
    while IFS= read -r line; do baselines+=("${line}"); done < "${baseline_file}"
  fi

  while true; do
    local idx=$(( RANDOM % 5 ))
    local qname="${QUERY_NAMES[$idx]}"
    local base_ms="${baselines[$idx]:-?}"
    local q
    q=$(get_query $idx)

    local start_ns end_ns elapsed_ms
    start_ns=$(date +%s%N 2>/dev/null || date +%s)
    ${gsql_cmd} -t -A -c "${q}" >/dev/null 2>&1
    end_ns=$(date +%s%N 2>/dev/null || date +%s)

    if [[ ${#start_ns} -gt 10 ]]; then
      elapsed_ms=$(( (end_ns - start_ns) / 1000000 ))
    else
      elapsed_ms=$(( (end_ns - start_ns) * 1000 ))
    fi

    local ratio=""
    if [[ "${base_ms}" != "?" ]] && [[ "${base_ms}" -gt 0 ]]; then
      local x=$(( elapsed_ms * 10 / base_ms ))
      ratio=" ($(( x / 10 )).$(( x % 10 ))x)"
    fi

    local tag=""
    if [[ ${elapsed_ms} -ge 1000 ]]; then
      tag=" !! SLOW !!"
    elif [[ ${elapsed_ms} -ge 200 ]]; then
      tag=" * slow"
    fi

    printf '[%s] WORKLOAD[%d] %-10s 基线 %s ms → %6d ms%s%s\n' \
      "$(date '+%F %T')" "${worker_id}" "${qname}" "${base_ms}" "${elapsed_ms}" "${ratio}" "${tag}"

    sleep "${interval}"
  done
}

# ── Demo workload ────────────────────────────────────────────────────────────
demo_workload_worker() {
  local worker_id=$1
  local interval=$2
  local base_times=(3 12 35 8 20)
  local tick=0

  while true; do
    tick=$((tick + 1))
    local idx=$(( RANDOM % 5 ))
    local qname="${QUERY_NAMES[$idx]}"
    local base=${base_times[$idx]}
    local multiplier=$(( 1 + tick / 3 ))
    local jitter=$(( RANDOM % (base / 2 + 1) ))
    local elapsed_ms=$(( base * multiplier + jitter ))

    # 模拟间歇性阻塞 (DDL 拿到锁后短暂 cascade block)
    if (( RANDOM % 5 == 0 )); then
      elapsed_ms=$(( elapsed_ms * (3 + RANDOM % 8) ))
    fi

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

demo_ddl_worker() {
  local worker_id=$1
  local interval=$2
  local ddl_names=("CHECKPOINT" "ALTER TABLE" "REINDEX" "ANALYZE" "VACUUM")
  local tick=0

  while true; do
    tick=$((tick + 1))
    local idx=$(( RANDOM % 5 ))
    local elapsed_ms=$(( 2000 + RANDOM % 8000 ))
    local tag=" !! BLOCKED !!"
    if [[ ${elapsed_ms} -lt 5000 ]]; then tag=" * waiting"; fi

    printf '[%s] DDL[%d] %-14s %6d ms%s\n' \
      "$(date '+%F %T')" "${worker_id}" "${ddl_names[$idx]}" "${elapsed_ms}" "${tag}"
    sleep "${interval}"
  done
}

# ── Phase 5: 验证故障效果 ────────────────────────────────────────────────────
phase_verify() {
  info "===== Phase 5: 验证故障效果 ====="

  if [[ "${DRY_RUN}" == "true" ]]; then
    info "[demo] 备份状态: pg_is_in_backup = true"
    info "[demo] 等锁会话: 5 个 (CHECKPOINT, DDL 被阻塞)"
    info "[demo] 等待事件: BarrierLock"
    return 0
  fi

  # 备份状态
  info "── 备份状态 ──"
  sql_verbose "SELECT pg_is_in_backup() AS in_backup"

  # 被阻塞的会话 (GaussDB: 用 pg_locks granted=false 找等锁会话, 不依赖 wait_event 列)
  info "── 等锁会话 ──"
  sql_verbose "SELECT a.pid, a.state, l.locktype, l.mode,
      now() - a.query_start AS wait_duration,
      a.application_name, left(a.query, 60) AS query
    FROM pg_stat_activity a
    JOIN pg_locks l ON l.pid = a.pid
    WHERE l.granted = false
      AND a.pid <> pg_backend_pid()
    ORDER BY a.query_start"

  # 查询耗时对比
  info ""
  info "╔══════════════════════════════════════════════════╗"
  info "║      5 条标准查询 — 注入前后对比                ║"
  info "╚══════════════════════════════════════════════════╝"

  local base_times=()
  if [[ -f "${BASELINE_FILE}" ]]; then
    while IFS= read -r line; do base_times+=("${line}"); done < "${BASELINE_FILE}"
  fi

  for i in 0 1 2 3 4; do
    local q qname base_ms now_ms ratio
    q=$(get_query $i)
    qname="${QUERY_NAMES[$i]}"
    base_ms="${base_times[$i]:-?}"
    now_ms=$(bench_ms "${q}")

    ratio="?"
    if [[ "${base_ms}" != "?" ]] && [[ "${base_ms}" -gt 0 ]]; then
      local x=$(( now_ms * 10 / base_ms ))
      ratio="$(( x / 10 )).$(( x % 10 ))x"
    fi

    info ""
    info "── Q$((i+1)): ${qname} ──"
    info "耗时:  基线 ${base_ms} ms → 当前 ${now_ms} ms  (${ratio})"

    if [[ -f "${BASELINE_PLAN_DIR}/${i}.txt" ]]; then
      info "[基线计划]"
      while IFS= read -r line; do
        [[ -n "${line}" ]] && info "  ${line}"
      done < "${BASELINE_PLAN_DIR}/${i}.txt"
    fi

    info "[当前计划]"
    sql_verbose "EXPLAIN ANALYZE ${q}" 2>&1 | while IFS= read -r line; do
      [[ -n "${line}" ]] && info "  ${line}"
    done
  done

  info "故障验证完成 ✓"
}

# ── Phase 6: 启动流量 ────────────────────────────────────────────────────────
phase_workload() {
  info "===== Phase 6: 启动业务流量 + DDL 冲突 ====="

  if [[ "${DRY_RUN}" == "true" ]]; then
    info "DRY_RUN=true → demo 模式"
    for i in $(seq 1 "${WORKLOAD_CONCURRENCY}"); do
      demo_workload_worker "${i}" "${WORKLOAD_INTERVAL}" &
      WORKLOAD_PIDS+=($!)
    done
    for i in $(seq 1 "${DDL_CONCURRENCY}"); do
      demo_ddl_worker "${i}" "${DDL_INTERVAL}" &
      DDL_PIDS+=($!)
    done
    return 0
  fi

  # 真实业务流量
  for i in $(seq 1 "${WORKLOAD_CONCURRENCY}"); do
    workload_worker "${i}" "${WORKLOAD_INTERVAL}" "${GSQL}" "${BASELINE_FILE}" &
    WORKLOAD_PIDS+=($!)
    info "业务 worker ${i} 已启动 (pid=${WORKLOAD_PIDS[-1]})"
  done

  # DDL 冲突制造器 — 这些操作会跟备份锁冲突, 产生 BarrierLock 等待
  for i in $(seq 1 "${DDL_CONCURRENCY}"); do
    ddl_conflict_worker "${i}" "${SCHEMA}" "${DDL_INTERVAL}" "${GSQL}" &
    DDL_PIDS+=($!)
    info "DDL 冲突 worker ${i} 已启动 (pid=${DDL_PIDS[-1]})"
  done

  info "流量启动完成 ✓"
}

# ── Phase 7: 观测等待 ────────────────────────────────────────────────────────
phase_observe() {
  info "╔═══════════════════════════════════════════════════╗"
  info "║  业务系统出现异常, 请排查                         ║"
  info "║                                                   ║"
  info "║  现象: 部分 SQL 间歇性卡顿, DDL 操作长时间挂起   ║"
  info "║  影响: 定时任务超时, 用户反馈页面偶尔卡住         ║"
  info "║                                                   ║"
  info "║  请登录数据库排查并恢复                           ║"
  info "║  Ctrl+C 结束演练 → 自动清理                       ║"
  info "╚═══════════════════════════════════════════════════╝"

  local tick=0
  local start_epoch
  start_epoch=$(date +%s)

  while true; do
    tick=$((tick + 1))

    if [[ "${DRY_RUN}" != "true" ]]; then
      if (( tick % 4 == 0 )); then
        echo ""
        local now_epoch elapsed_min
        now_epoch=$(date +%s)
        elapsed_min=$(( (now_epoch - start_epoch) / 60 ))

        # 采一条业务查询耗时
        local probe_ms=0
        probe_ms=$(bench_ms "$(get_query 2)")
        # 防御: 非数字时归零 (避免后续整数比较报错)
        [[ "${probe_ms}" =~ ^[0-9]+$ ]] || probe_ms=0

        # 统计等锁会话数 (GaussDB 兼容: 用 pg_locks granted=false)
        local waiting_count=0
        waiting_count=$(sql "SELECT count(DISTINCT pid) FROM pg_locks
                             WHERE granted = false
                               AND pid <> pg_backend_pid()" 2>/dev/null | tr -d ' ')
        [[ "${waiting_count}" =~ ^[0-9]+$ ]] || waiting_count=0

        info "── 告警 #${tick}  已持续 ${elapsed_min} 分钟 ──"
        info "业务查询响应: ${probe_ms} ms | 等待中会话: ${waiting_count}"

        if [[ ${probe_ms} -ge 1000 ]] || [[ ${waiting_count} -ge 3 ]]; then
          info "告警级别: P1 - 严重"
        elif [[ ${probe_ms} -ge 200 ]]; then
          info "告警级别: P2 - 警告"
        else
          info "告警级别: 正常"
        fi

        # 静默检测恢复: 备份已停止
        local in_backup
        in_backup=$(sql "SELECT pg_is_in_backup();" 2>/dev/null || echo "t")
        local backup_alive
        backup_alive=$(sql "SELECT count(*) FROM pg_stat_activity
                            WHERE application_name = 'fault_drill_backup'")

        if [[ "${in_backup}" != "t" ]] && [[ "${backup_alive}" == "0" ]]; then
          sleep "${OBSERVE_INTERVAL}"
          probe_ms=$(bench_ms "$(get_query 2)")
          local base_times=()
          if [[ -f "${BASELINE_FILE}" ]]; then
            while IFS= read -r line; do base_times+=("${line}"); done < "${BASELINE_FILE}"
          fi
          local base_ms="${base_times[2]:-1}"

          echo ""
          info "╔═══════════════════════════════════════════════════╗"
          info "║  演练结束!                                        ║"
          info "║                                                   ║"
          info "║  恢复耗时: ${elapsed_min} 分钟                             ║"
          info "║  业务查询: 基线 ${base_ms} ms → 当前 ${probe_ms} ms           ║"
          if [[ ${probe_ms} -le $(( base_ms * 2 )) ]]; then
            info "║  状态: 已恢复正常 ✓                               ║"
          else
            info "║  状态: 部分恢复                                   ║"
          fi
          info "╚═══════════════════════════════════════════════════╝"
          return 0
        fi
      fi

      check_abort || { warn "触发中止条件, 退出"; return 1; }
    else
      if (( tick % 4 == 0 )); then
        local sim_elapsed=$(( tick * OBSERVE_INTERVAL / 60 ))
        echo ""
        info "── [demo] 告警 #${tick}  已持续 ${sim_elapsed} 分钟 ──"
        info "业务查询响应: $(( 200 + RANDOM % 800 )) ms | 等待中会话: $(( 3 + RANDOM % 5 ))"
        info "告警级别: P1 - 严重"
      fi
    fi

    sleep "${OBSERVE_INTERVAL}"
  done
}

###############################################################################
main() {
  info "╔═══════════════════════════════════════════════════╗"
  info "║  GaussDB 故障演练: 备份卡住 → BarrierLock        ║"
  info "╠═══════════════════════════════════════════════════╣"
  info "║  DRY_RUN=${DRY_RUN}                                      ║"
  info "║  DB=${GSQL}              ║"
  info "╚═══════════════════════════════════════════════════╝"

  phase_precheck
  phase_seed
  phase_baseline
  phase_inject_backup
  phase_verify
  phase_workload
  phase_observe
}

main "$@"
