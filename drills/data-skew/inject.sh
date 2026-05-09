#!/usr/bin/env bash
###############################################################################
# GaussDB 故障演练 — 分布式数据分布不均衡导致 SQL 整体变慢
#
# 故障链路:
#   分布列选低基数列 (status, 5 个值)
#     → hash(status) 把 90%+ 数据路由到同一个 DN
#       → 3 个 DN 数据量极不均衡 (倾斜 DN 行数是其他 DN 几十倍)
#         → 聚合/JOIN/全表扫描时倾斜 DN 成为瓶颈, 其他 DN 空等
#           → 整体 SQL 响应时间被拖慢
#
# 使用方式:
#   bash inject.sh                                          # demo 模式, 模拟输出
#   DRY_RUN=false GSQL="gsql -d mydb -p 5432" bash inject.sh  # 实际注入
#
# 退出即清理 — Ctrl+C / kill / SSH 断开 都会自动回滚
# 单文件, scp 到服务器直接跑, 无外部依赖
#
# 前提: GaussDB 分布式部署 (CN + 多 DN), 推荐 ≥ 3 DN
###############################################################################
set -uo pipefail

# ── 可调参数 (全部通过环境变量覆盖) ──────────────────────────────────────────
GSQL="${GSQL:-gsql -d postgres -p 5432}"           # 数据库连接命令
DRY_RUN="${DRY_RUN:-true}"                         # true=只打印不执行
SCHEMA="${SCHEMA:-fault_drill}"                    # 演练用 schema
TABLE_SKEW="${TABLE_SKEW:-drill_skew}"             # 倾斜表 (分布列选错)
TABLE_BAL="${TABLE_BAL:-drill_balanced}"           # 对照组: 均衡分布表
SEED_ROWS="${SEED_ROWS:-3000000}"                  # 种子数据行数 (300万)
SKEW_PCT="${SKEW_PCT:-90}"                         # 倾斜值占比 (%, 默认 90%)
OBSERVE_INTERVAL="${OBSERVE_INTERVAL:-30}"         # 观测采集间隔 (秒)
ABORT_CONN_PCT="${ABORT_CONN_PCT:-80}"             # 连接数中止阈值
DROP_ON_EXIT="${DROP_ON_EXIT:-false}"              # true=退出时删除演练 schema
WORKLOAD_INTERVAL="${WORKLOAD_INTERVAL:-3}"        # 业务流量间隔 (秒)
WORKLOAD_CONCURRENCY="${WORKLOAD_CONCURRENCY:-4}"  # 业务并发数
STATEMENT_TIMEOUT_MS="${STATEMENT_TIMEOUT_MS:-60000}"  # SQL 超时 (ms), 60s

# ── 5 条标准查询 (基线/验证/workload 共用) ─────────────────────────────────────
# 全部针对聚合/JOIN/全表扫描 — 倾斜对这些影响最大
QUERY_NAMES=("全表count" "条件聚合" "TopN汇总" "自JOIN" "多维聚合")

# 第一个参数是表名 (在两张表上跑同样 5 条)
get_query() {
  local i=$1
  local tbl="${SCHEMA}.$2"
  case $i in
    0) echo "SELECT count(*) FROM ${tbl}" ;;
    1) echo "SELECT region, count(*), avg(amount) FROM ${tbl} WHERE status='pending' GROUP BY region" ;;
    2) echo "SELECT user_id, sum(amount) AS total FROM ${tbl} GROUP BY user_id ORDER BY total DESC LIMIT 100" ;;
    3) echo "SELECT a.region, count(*) FROM ${tbl} a JOIN ${tbl} b ON a.user_id = b.user_id WHERE a.status='pending' AND b.status='paid' GROUP BY a.region" ;;
    4) echo "SELECT status, region, count(*), avg(amount) FROM ${tbl} GROUP BY status, region ORDER BY count(*) DESC" ;;
  esac
}

# ── 内部状态 ──────────────────────────────────────────────────────────────────
SEED_CREATED=false
BASELINE_FILE="/tmp/fault_drill_skew_baseline_$$.dat"      # 基线表耗时
BASELINE_PLAN_DIR="/tmp/fault_drill_skew_plans_$$"          # 基线 EXPLAIN
WORKLOAD_PIDS=()

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
  ${GSQL} -t -A -c "SET statement_timeout = ${STATEMENT_TIMEOUT_MS}; $1" >/dev/null 2>&1
  end_ns=$(date +%s%N 2>/dev/null || date +%s)
  if [[ ${#start_ns} -gt 10 ]]; then
    elapsed=$(( (end_ns - start_ns) / 1000000 ))
  else
    elapsed=$(( (end_ns - start_ns) * 1000 ))
  fi
  echo "${elapsed}"
}

# ── 清理函数 ─────────────────────────────────────────────────────────────────
cleanup() {
  local exit_code=$?
  echo ""
  info "╔═══════════════════════════════════════╗"
  info "║          自动清理开始                 ║"
  info "║  exit_code=${exit_code}                          ║"
  info "╚═══════════════════════════════════════╝"

  # 0) 杀业务流量
  if [[ ${#WORKLOAD_PIDS[@]} -gt 0 ]]; then
    info "[清理 1/3] 停止业务流量 (${#WORKLOAD_PIDS[@]} 个进程)"
    for wpid in "${WORKLOAD_PIDS[@]}"; do kill "${wpid}" 2>/dev/null || true; done
    for wpid in "${WORKLOAD_PIDS[@]}"; do wait "${wpid}" 2>/dev/null || true; done
  fi

  # 1) 数据库侧兜底: 杀残留会话
  if [[ "${DRY_RUN}" != "true" ]]; then
    info "[清理 2/3] pg_terminate_backend 清理演练会话"
    sql "SELECT pg_terminate_backend(pid)
         FROM pg_stat_activity
         WHERE application_name LIKE 'fault_drill_skew%'
           AND pid <> pg_backend_pid();" || true
  fi

  # 2) 可选: 删除演练 schema (含 drill_skew + drill_balanced + 任何 SRE 修复表)
  if [[ "${DROP_ON_EXIT}" == "true" ]] && [[ "${SEED_CREATED}" == "true" ]]; then
    info "[清理 3/3] DROP SCHEMA ${SCHEMA} CASCADE"
    sql "DROP SCHEMA IF EXISTS ${SCHEMA} CASCADE;" || true
  else
    info "[清理 3/3] 保留演练数据 (DROP_ON_EXIT=true 可自动删除)"
  fi

  rm -f /tmp/fault_drill_skew_baseline_*.dat 2>/dev/null || true
  rm -rf /tmp/fault_drill_skew_plans_* 2>/dev/null || true

  info "清理完成 ✓"
}

trap cleanup EXIT INT TERM HUP

# ── 中止条件 ─────────────────────────────────────────────────────────────────
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

  if [[ "${DRY_RUN}" == "true" ]]; then
    info "DRY-RUN: 跳过前置检查"
    return 0
  fi

  sql "SELECT 1;" >/dev/null || { err "无法连接数据库"; exit 1; }
  info "数据库连接 ✓"

  # 必须是分布式部署 — pgxc_node 视图存在 + 至少 2 个 DN
  local dn_count
  dn_count=$(sql "SELECT count(*) FROM pgxc_node WHERE node_type='D'" 2>/dev/null | tr -d ' ')
  if [[ -z "${dn_count}" ]] || [[ "${dn_count}" == "0" ]]; then
    err "未检测到分布式部署 (pgxc_node 中无 DN), 此场景需要分布式 GaussDB"
    err "如果是集中式部署, 请改用 dead-tuple-bloat 等场景"
    exit 1
  fi
  info "分布式部署确认: ${dn_count} 个 DN ✓"

  # 检测 pgxc_get_table_skewness 是否可用
  local has_skewness_fn
  has_skewness_fn=$(sql "SELECT count(*) FROM pg_proc
                         WHERE proname='pgxc_get_table_skewness'" 2>/dev/null | tr -d ' ')
  if [[ "${has_skewness_fn}" == "0" ]]; then
    warn "pgxc_get_table_skewness() 不可用, 将降级用 pgxc_node_id 隐藏列"
  else
    info "pgxc_get_table_skewness() 可用 ✓"
  fi

  # 清理上次遗留的会话
  local stale
  stale=$(sql "SELECT count(*) FROM pg_stat_activity
               WHERE application_name LIKE 'fault_drill_skew%'" 2>/dev/null | tr -d ' ')
  if [[ -n "${stale}" ]] && (( stale > 0 )); then
    warn "清理 ${stale} 个遗留演练会话"
    sql "SELECT pg_terminate_backend(pid) FROM pg_stat_activity
         WHERE application_name LIKE 'fault_drill_skew%'
           AND pid <> pg_backend_pid();" || true
  fi

  check_abort || { err "前置检查未通过中止条件"; exit 1; }
  info "前置检查通过 ✓"
}

# ── Phase 1: 创建种子数据 (两张表: 倾斜 + 均衡) ──────────────────────────────
phase_seed() {
  info "===== Phase 1: 创建种子数据 (${SEED_ROWS} 行 x 2 表) ====="

  # schema
  local schema_exists
  schema_exists=$(sql "SELECT count(*) FROM pg_namespace WHERE nspname='${SCHEMA}'")
  if [[ "${schema_exists}" == "0" ]] || [[ "${DRY_RUN}" == "true" ]]; then
    sql "CREATE SCHEMA ${SCHEMA};"
  fi
  sql "DROP TABLE IF EXISTS ${SCHEMA}.${TABLE_SKEW};"
  sql "DROP TABLE IF EXISTS ${SCHEMA}.${TABLE_BAL};"

  # 对照组: 分布列 = id (高基数, 数据均匀分布到所有 DN)
  info "创建对照表 ${SCHEMA}.${TABLE_BAL} — DISTRIBUTE BY HASH(id) (高基数, 均衡)"
  sql "CREATE TABLE ${SCHEMA}.${TABLE_BAL} (
         id         BIGSERIAL      NOT NULL,
         user_id    INT            NOT NULL,
         amount     NUMERIC(12,2)  NOT NULL,
         status     VARCHAR(20)    NOT NULL,
         region     VARCHAR(10)    NOT NULL,
         created_at TIMESTAMP      NOT NULL DEFAULT now()
       ) DISTRIBUTE BY HASH(id);"

  # 倾斜组: 分布列 = status (低基数: 只有 5 个值, 且 90% 是 'pending')
  info "创建倾斜表 ${SCHEMA}.${TABLE_SKEW} — DISTRIBUTE BY HASH(status) (低基数, 严重倾斜)"
  sql "CREATE TABLE ${SCHEMA}.${TABLE_SKEW} (
         id         BIGSERIAL      NOT NULL,
         user_id    INT            NOT NULL,
         amount     NUMERIC(12,2)  NOT NULL,
         status     VARCHAR(20)    NOT NULL,
         region     VARCHAR(10)    NOT NULL,
         created_at TIMESTAMP      NOT NULL DEFAULT now()
       ) DISTRIBUTE BY HASH(status);"

  sql "CREATE INDEX idx_skew_user ON ${SCHEMA}.${TABLE_SKEW}(user_id);"
  sql "CREATE INDEX idx_bal_user  ON ${SCHEMA}.${TABLE_BAL}(user_id);"

  # 数据生成: 故意让 status 极不均匀
  # SKEW_PCT (默认 90%) 的行 status='pending', 剩余 10% 平均分给其他 4 个值
  info "灌入 ${SEED_ROWS} 行数据 (${SKEW_PCT}% status='pending', 制造倾斜)..."
  sql "INSERT INTO ${SCHEMA}.${TABLE_SKEW} (user_id, amount, status, region)
       SELECT
         (random()*10000)::INT,
         (random()*9999+1)::NUMERIC(12,2),
         CASE
           WHEN random() * 100 < ${SKEW_PCT} THEN 'pending'
           WHEN random() < 0.25 THEN 'paid'
           WHEN random() < 0.5  THEN 'shipped'
           WHEN random() < 0.75 THEN 'done'
           ELSE 'cancelled'
         END,
         (ARRAY['east','west','north','south','central'])
           [floor(random()*5+1)::INT]
       FROM generate_series(1, ${SEED_ROWS});"

  # 对照表用同样的数据 (从倾斜表复制, 避免 random() 两次结果不同)
  info "灌入对照表 (复制自倾斜表, 数据相同, 仅分布列不同)..."
  sql "INSERT INTO ${SCHEMA}.${TABLE_BAL} (id, user_id, amount, status, region, created_at)
       SELECT id, user_id, amount, status, region, created_at FROM ${SCHEMA}.${TABLE_SKEW};"

  sql "ANALYZE ${SCHEMA}.${TABLE_SKEW};"
  sql "ANALYZE ${SCHEMA}.${TABLE_BAL};"

  SEED_CREATED=true
  info "种子数据就绪 ✓"

  # 立刻打印两张表的分布情况, 给注入者 (出题人) 看效果
  if [[ "${DRY_RUN}" != "true" ]]; then
    info ""
    info "── 倾斜表 ${TABLE_SKEW} 各 DN 行数分布 ──"
    sql_verbose "SELECT * FROM pgxc_get_table_skewness('${SCHEMA}.${TABLE_SKEW}')" 2>/dev/null \
      || sql_verbose "SELECT pgxc_node_id, count(*) AS rows FROM ${SCHEMA}.${TABLE_SKEW}
                      GROUP BY pgxc_node_id ORDER BY rows DESC"
    info ""
    info "── 对照表 ${TABLE_BAL} 各 DN 行数分布 ──"
    sql_verbose "SELECT * FROM pgxc_get_table_skewness('${SCHEMA}.${TABLE_BAL}')" 2>/dev/null \
      || sql_verbose "SELECT pgxc_node_id, count(*) AS rows FROM ${SCHEMA}.${TABLE_BAL}
                      GROUP BY pgxc_node_id ORDER BY rows DESC"
  fi
}

# ── Phase 2: 记录基线 (在均衡表上) ───────────────────────────────────────────
phase_baseline() {
  info "===== Phase 2: 在均衡表上记录基线 ====="

  if [[ "${DRY_RUN}" == "true" ]]; then
    info "DRY-RUN: 跳过基线"
    return 0
  fi

  mkdir -p "${BASELINE_PLAN_DIR}"
  > "${BASELINE_FILE}"

  info "┌──────────────────────────────────────────────────┐"
  info "│  基线 (均衡表 ${TABLE_BAL}) 耗时 + EXPLAIN 计划"
  for i in 0 1 2 3 4; do
    local q ms
    q=$(get_query $i "${TABLE_BAL}")
    ms=$(bench_ms "${q}")
    echo "${ms}" >> "${BASELINE_FILE}"
    sql_verbose "EXPLAIN ${q}" > "${BASELINE_PLAN_DIR}/${i}.txt" 2>&1
    info "│ ${QUERY_NAMES[$i]}:  ${ms} ms"
  done
  info "└──────────────────────────────────────────────────┘"
  info "基线记录完成 ✓"
}

# ── Phase 3: 验证故障效果 (倾斜表 vs 均衡表对比) ─────────────────────────────
phase_verify() {
  info "===== Phase 3: 倾斜 vs 均衡 — 性能对比 ====="

  if [[ "${DRY_RUN}" == "true" ]]; then
    info "[demo] 倾斜表 DN1=2700000 行, DN2=150000 行, DN3=150000 行 (倾斜度 ~94%)"
    info "[demo] 均衡表 DN1=1000000 行, DN2=1000000 行, DN3=1000000 行"
    info "[demo] 全表count: 基线 320 ms → 倾斜 1850 ms (5.8x)"
    info "[demo] 自JOIN:  基线 4200 ms → 倾斜 32100 ms (7.6x)"
    return 0
  fi

  # 倾斜度报告
  info "── 倾斜度分析 ──"
  sql_verbose "SELECT * FROM pgxc_get_table_skewness('${SCHEMA}.${TABLE_SKEW}')" 2>/dev/null \
    || sql_verbose "SELECT pgxc_node_id, count(*) AS rows,
                       round(100.0 * count(*) / sum(count(*)) OVER (), 1) AS pct
                    FROM ${SCHEMA}.${TABLE_SKEW}
                    GROUP BY pgxc_node_id ORDER BY rows DESC"

  info ""
  info "╔══════════════════════════════════════════════════╗"
  info "║   5 条标准查询 — 均衡表 vs 倾斜表 对比          ║"
  info "╚══════════════════════════════════════════════════╝"

  local base_times=()
  if [[ -f "${BASELINE_FILE}" ]]; then
    while IFS= read -r line; do base_times+=("${line}"); done < "${BASELINE_FILE}"
  fi

  for i in 0 1 2 3 4; do
    local q qname base_ms now_ms ratio
    qname="${QUERY_NAMES[$i]}"
    base_ms="${base_times[$i]:-?}"
    q=$(get_query $i "${TABLE_SKEW}")
    now_ms=$(bench_ms "${q}")

    ratio="?"
    if [[ "${base_ms}" != "?" ]] && [[ "${base_ms}" -gt 0 ]]; then
      local x=$(( now_ms * 10 / base_ms ))
      ratio="$(( x / 10 )).$(( x % 10 ))x"
    fi

    info ""
    info "── Q$((i+1)): ${qname} ──"
    info "耗时:  均衡表 ${base_ms} ms → 倾斜表 ${now_ms} ms  (${ratio})"
  done

  info ""
  info "故障效果验证完成 ✓ (倾斜表已就绪, 业务即将打到倾斜表)"
}

# ── 业务流量 worker (打到倾斜表) ─────────────────────────────────────────────
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
    q=$(get_query $idx "${TABLE_SKEW}")

    local start_ns end_ns elapsed_ms
    start_ns=$(date +%s%N 2>/dev/null || date +%s)
    ${gsql_cmd} -t -A -c "SET application_name = 'fault_drill_skew_workload';
                          SET statement_timeout = ${STATEMENT_TIMEOUT_MS};
                          ${q}" >/dev/null 2>&1
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

    printf '[%s] WORKLOAD[%d] %-12s 基线 %s ms → %6d ms%s%s\n' \
      "$(date '+%F %T')" "${worker_id}" "${qname}" "${base_ms}" "${elapsed_ms}" "${ratio}" "${tag}"

    sleep "${interval}"
  done
}

# ── Demo workload ────────────────────────────────────────────────────────────
demo_workload_worker() {
  local worker_id=$1
  local interval=$2

  local query_names=("全表count" "条件聚合" "TopN汇总" "自JOIN" "多维聚合")
  local base_times=(320 480 1100 4200 950)
  local skew_mult=(5 6 7 8 6)
  local tick=0

  while true; do
    tick=$((tick + 1))
    local idx=$(( RANDOM % ${#query_names[@]} ))
    local qname="${query_names[$idx]}"
    local base=${base_times[$idx]}
    local mult=${skew_mult[$idx]}
    local jitter=$(( RANDOM % (base / 4 + 1) ))
    local elapsed_ms=$(( base * mult + jitter ))

    local tag=""
    if [[ ${elapsed_ms} -ge 1000 ]]; then
      tag=" !! SLOW !!"
    elif [[ ${elapsed_ms} -ge 200 ]]; then
      tag=" * slow"
    fi

    printf '[%s] WORKLOAD[%d] %-12s 基线 %d ms → %6d ms (%dx)%s\n' \
      "$(date '+%F %T')" "${worker_id}" "${qname}" "${base}" "${elapsed_ms}" "${mult}" "${tag}"

    sleep "${interval}"
  done
}

# ── Phase 4: 启动业务流量 ────────────────────────────────────────────────────
phase_workload() {
  info "===== Phase 4: 启动业务流量 (打到倾斜表) ====="

  if [[ "${DRY_RUN}" == "true" ]]; then
    info "DRY_RUN=true → 启动 demo 模式"
    for i in $(seq 1 "${WORKLOAD_CONCURRENCY}"); do
      demo_workload_worker "${i}" "${WORKLOAD_INTERVAL}" &
      WORKLOAD_PIDS+=($!)
    done
    info "Demo 业务流量启动 ✓ (${WORKLOAD_CONCURRENCY} 并发)"
    return 0
  fi

  for i in $(seq 1 "${WORKLOAD_CONCURRENCY}"); do
    workload_worker "${i}" "${WORKLOAD_INTERVAL}" "${GSQL}" "${BASELINE_FILE}" &
    WORKLOAD_PIDS+=($!)
    info "业务 worker ${i} 启动 (pid=${WORKLOAD_PIDS[-1]})"
  done
  info "业务流量启动 ✓ (${WORKLOAD_CONCURRENCY} 并发, 间隔 ${WORKLOAD_INTERVAL}s)"
}

# ── Phase 5: 观测等 SRE 排查 ─────────────────────────────────────────────────
# 倾斜场景的"恢复"判定:
#   SRE 修复后, 在 schema 里建一个 ${TABLE_SKEW}_fixed 表, 演练自动结束
#   (或者 SRE 也可以重建原表 — 检测原表分布是否均衡)
phase_observe() {
  info "╔═══════════════════════════════════════════════════╗"
  info "║  业务系统出现异常, 请排查                         ║"
  info "║                                                   ║"
  info "║  现象: 业务查询响应时间整体升高                   ║"
  info "║  影响: 报表/聚合/JOIN 类查询尤其慢                ║"
  info "║                                                   ║"
  info "║  请登录数据库排查并恢复                           ║"
  info "║  恢复后建表 ${SCHEMA}.${TABLE_SKEW}_fixed           ║"
  info "║  作为完成标记, 演练自动结束                       ║"
  info "║  Ctrl+C 也可结束演练 → 自动清理                   ║"
  info "╚═══════════════════════════════════════════════════╝"

  local tick=0
  local start_epoch
  start_epoch=$(date +%s)

  while true; do
    tick=$((tick + 1))

    if [[ "${DRY_RUN}" != "true" ]]; then
      if (( tick % 4 == 0 )); then
        echo ""
        local now_epoch elapsed_min probe_ms=0
        now_epoch=$(date +%s)
        elapsed_min=$(( (now_epoch - start_epoch) / 60 ))

        # 采一条聚合的耗时
        probe_ms=$(bench_ms "$(get_query 1 "${TABLE_SKEW}")")
        [[ "${probe_ms}" =~ ^[0-9]+$ ]] || probe_ms=0

        info "── 告警 #${tick}  已持续 ${elapsed_min} 分钟 ──"
        info "业务查询响应: ${probe_ms} ms"

        if [[ ${probe_ms} -ge 2000 ]]; then
          info "告警级别: P1 - 严重"
        elif [[ ${probe_ms} -ge 500 ]]; then
          info "告警级别: P2 - 警告"
        else
          info "告警级别: 正常"
        fi

        # 静默检测: SRE 是否建了 ${TABLE_SKEW}_fixed 标记表
        local fixed_exists=0
        fixed_exists=$(sql "SELECT count(*) FROM pg_tables
                            WHERE schemaname='${SCHEMA}'
                              AND tablename='${TABLE_SKEW}_fixed'" \
                              2>/dev/null | tr -d ' ')
        [[ "${fixed_exists}" =~ ^[0-9]+$ ]] || fixed_exists=0

        if [[ "${fixed_exists}" -gt 0 ]]; then
          # 验证 fixed 表是否真的均衡了
          local max_pct
          max_pct=$(sql "SELECT round(100.0 * max(c) / sum(c)) FROM (
                          SELECT count(*) AS c FROM ${SCHEMA}.${TABLE_SKEW}_fixed
                          GROUP BY pgxc_node_id) t" 2>/dev/null | tr -d ' ')
          [[ "${max_pct}" =~ ^[0-9]+$ ]] || max_pct=100

          echo ""
          info "╔═══════════════════════════════════════════════════╗"
          info "║  演练结束!                                        ║"
          info "║                                                   ║"
          info "║  恢复耗时: ${elapsed_min} 分钟"
          info "║  ${TABLE_SKEW}_fixed 表最大 DN 占比: ${max_pct}%"
          if [[ "${max_pct}" -le 50 ]]; then
            info "║  状态: 已恢复正常, 数据分布均衡 ✓                "
          else
            info "║  状态: 修复表仍有倾斜, 检查分布键选择            "
          fi
          info "╚═══════════════════════════════════════════════════╝"
          return 0
        fi
      fi
      check_abort || { warn "触发中止条件, 退出"; return 1; }
    else
      # demo 模式: 模拟告警
      if (( tick % 4 == 0 )); then
        echo ""
        info "── [demo] 告警 #${tick} ──"
        info "业务查询响应: $((1500 + RANDOM % 2000)) ms | 告警级别: P1"
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
  info "║  GaussDB 故障演练: 数据分布不均衡     ║"
  info "╠═══════════════════════════════════════╣"
  info "║  DRY_RUN=${DRY_RUN}"
  info "║  DB=${GSQL}"
  info "║  种子: ${SEED_ROWS} 行 x 2 表"
  info "║  倾斜值占比: ${SKEW_PCT}%"
  info "╚═══════════════════════════════════════╝"

  phase_precheck
  phase_seed
  phase_baseline
  phase_verify
  phase_workload
  phase_observe
}

main "$@"
