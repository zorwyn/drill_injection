# Scenario catalog

Use this catalog to map the user's request to a safe pattern.

## `cpu-saturation`

- Required params: `workers`, `duration_min`, one of `load_pct` or `cpu_count`
- Prefer: `stress-ng` or container and cgroup scoped CPU pressure
- Guardrails: limit scope to one host, cap worker count, abort on SQL latency or load threshold
- Verify: CPU utilization, load average, SQL latency, replication lag
- Rollback: stop the load process and verify CPU returns to baseline

## `memory-pressure`

- Required params: `bytes` or `percent`, `duration_min`
- Prefer: `stress-ng --vm`, cgroup memory limits, or temporary cache pressure
- Guardrails: keep headroom above OOM threshold, exclude system mount points, abort on OOM or swap storm
- Verify: RSS, swap usage, SQL latency, background process health
- Rollback: kill the injector and confirm memory recovers

## `disk-fill`

- Required params: `path`, `bytes` or `fill_pct`, `min_free_gb`, `duration_min`
- Prefer: dedicated temporary file under a drill directory on the target mount
- Guardrails: never target system root by default, keep explicit free-space floor, abort on replication lag or disk alarm
- Verify: free space, write latency, iowait, WAL or redo health
- Rollback: delete filler files, `sync`, and recheck free space

## `disk-throttle`

- Required params: `device` or `mount`, `read_bps` or `write_bps`, `duration_min`
- Prefer: cgroup or platform throttling over ad hoc device hacks
- Guardrails: confirm the device mapping first, limit to one node, abort on failover or unreachable service
- Verify: disk throughput, query latency, replication apply delay
- Rollback: remove throttling rules and confirm throughput recovery

## `network-delay`

- Required params: `interface`, `latency_ms`, `jitter_ms`, `duration_min`
- Prefer: `tc qdisc netem` on the specific service interface
- Guardrails: identify the interface and peer first, avoid management NICs, abort on packet loss above target
- Verify: RTT, replication lag, SQL latency, reconnect count
- Rollback: delete the injected `tc` rule and confirm route health

## `network-loss`

- Required params: `interface`, `loss_pct`, `duration_min`
- Prefer: `tc qdisc netem loss`
- Guardrails: keep loss targeted and time-bounded, avoid control-plane networks
- Verify: retransmits, session errors, replication lag
- Rollback: delete the `tc` rule and recheck connectivity

## `network-partition`

- Required params: `interface` or `peer`, `direction`, `duration_min`
- Prefer: targeted `iptables` or route blackhole rules
- Guardrails: isolate only the intended peer or port, use a strict timeout, abort on unexpected cluster role change
- Verify: peer reachability, failover state, reconnect behavior
- Rollback: remove the blocking rules and verify bidirectional recovery

## `process-stop`

- Required params: `process_name` or `pid`, `duration_min`
- Prefer: `SIGSTOP` and `SIGCONT` over force kill when simulating a hang
- Guardrails: confirm process ownership and supervisor behavior first
- Verify: health checks, session failures, recovery after resume
- Rollback: `SIGCONT` and confirm the process becomes healthy

## `process-kill`

- Required params: `process_name` or `pid`, `signal`, `restart_expectation`
- Prefer: controlled single-process termination
- Guardrails: confirm restart path and standby protection first
- Verify: restart duration, leader election or failover, client error rate
- Rollback: restart the service or let the supervisor recover it, then confirm steady state

## `sql-lock-contention`

- Required params: `database`, `schema`, `lock_object`, `hold_sec`
- Prefer: dedicated drill schema and two explicit sessions
- Guardrails: avoid shared business tables, bound the hold time, keep cleanup SQL ready
- Verify: blocked sessions, wait events, SQL RT, application retries
- Rollback: `ROLLBACK` or `COMMIT`, release locks, and confirm blocked sessions drain

## `slow-query-burst`

- Required params: `database`, `query_file` or `query_text`, `concurrency`, `duration_min`
- Prefer: replay against seeded test data with capped concurrency
- Guardrails: limit client count and QPS, avoid destructive SQL, abort on connection pool exhaustion
- Verify: query latency, CPU, buffer cache pressure, connection saturation
- Rollback: stop the workload driver and confirm recovery

## `replication-lag`

- Required params: `target_role`, `mechanism`, `duration_min`
- Prefer: inject network delay or standby-side I/O pressure instead of modifying database internals
- Guardrails: define max lag threshold and failover abort rule
- Verify: replay delay, WAL or redo backlog, role stability
- Rollback: remove the external pressure and confirm lag converges

## `dead-tuple-bloat`

- Required params: `database`, `schema`, `table`, `update_rows`, `txn_hold_sec`
- Prefer: multi-phase drill — open long transaction to pin xmin, bulk UPDATE to generate dead tuples, observe EXPLAIN plan degradation
- Guardrails: use dedicated drill table with seed data, cap update row count, bound transaction hold time, abort on replication lag or connection exhaustion
- Verify: dead tuple count via pg_stat_user_tables, autovacuum blocked state, EXPLAIN cost change, SQL p95 latency
- Rollback: kill the long-holding session, VACUUM the target table, confirm dead tuple count drops and plan cost normalizes

## `barrier-lock`

- Required params: `database`, `schema`, `table`, `backup_hold_sec`
- Prefer: multi-phase drill — call pg_start_backup() and hold it to simulate stuck backup, inject DDL conflict workers (CHECKPOINT/ALTER TABLE/REINDEX/VACUUM) to trigger BarrierLock contention, run business workload to expose cascading slowdown
- Guardrails: use dedicated drill table and schema, verify no existing backup before injection, cap backup hold time, abort on replication lag or connection exhaustion
- Verify: wait_event shows BarrierLock/BackupLock in pg_stat_activity, pg_is_in_backup() returns true, DDL operations blocked, business SQL latency elevated
- Rollback: pg_stop_backup() or pg_terminate_backend on the backup session, confirm pg_is_in_backup() returns false, verify blocked sessions drain and latency recovers

## `data-skew`

- Required params: `database`, `schema`, `table`, `seed_rows`, `skew_pct`
- Prefer: dual-table approach — create one table with poor distribution key (low-cardinality column like status) holding skewed data, plus a balanced control table with high-cardinality key (id), run the same OLAP queries on both for direct comparison
- Guardrails: requires distributed deployment with multiple DNs (script aborts on centralized), use dedicated drill schema, cap seed rows, abort on connection saturation, statement_timeout to prevent runaway queries
- Verify: pgxc_get_table_skewness() shows one DN holding 90%+ rows, EXPLAIN PERFORMANCE shows asymmetric DN execution time, aggregation/JOIN latency multiples vs balanced table
- Rollback: drop the schema (data skew is not auto-recoverable — fix is to rebuild table with proper DISTRIBUTE BY clause); drill ends when SRE creates a `<table>_fixed` marker table with balanced distribution

## `clock-skew`

- Required params: `offset_sec`, `duration_min`, `time_sync_service`
- Prefer: isolated lab environments only
- Guardrails: stop automatic time sync before injection, record original time, abort on certificate or auth errors
- Verify: time offset, session auth behavior, replication timestamps
- Rollback: restore system time, restart time sync, and verify convergence
