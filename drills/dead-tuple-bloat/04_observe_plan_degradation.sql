-- Phase 3: 观测查询计划退化
-- 运行 EXPLAIN 对比基线，观察优化器代价估算变化

-- 查询 1：范围扫描 + 聚合
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT region, count(*), avg(amount)
FROM fault_drill.drill_orders
WHERE status = 'pending'
GROUP BY region;

-- 查询 2：索引选择性测试
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT *
FROM fault_drill.drill_orders
WHERE user_id = 42 AND status = 'paid'
ORDER BY created_at DESC
LIMIT 20;

-- 查询 3：JOIN 场景（自连接模拟）
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT a.id, a.amount, b.amount
FROM fault_drill.drill_orders a
JOIN fault_drill.drill_orders b ON a.user_id = b.user_id
WHERE a.status = 'shipped' AND b.status = 'done'
LIMIT 100;

-- 表膨胀统计
SELECT
    schemaname,
    relname,
    n_live_tup,
    n_dead_tup,
    n_dead_tup::float / NULLIF(n_live_tup + n_dead_tup, 0) AS dead_ratio,
    pg_size_pretty(pg_total_relation_size('fault_drill.drill_orders')) AS total_size,
    last_autovacuum,
    last_autoanalyze
FROM pg_stat_user_tables
WHERE schemaname = 'fault_drill' AND relname = 'drill_orders';

-- autovacuum 阻塞状态
SELECT
    pid, state, backend_xmin, query_start,
    now() - query_start AS duration,
    application_name, query
FROM pg_stat_activity
WHERE application_name = 'fault_drill_long_tx'
   OR (query ILIKE '%autovacuum%' AND datname = current_database());
