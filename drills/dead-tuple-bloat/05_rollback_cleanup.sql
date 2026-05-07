-- Phase 4: 回滚与清理

-- Step 1: 终止长事务会话
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE application_name = 'fault_drill_long_tx'
  AND pid <> pg_backend_pid();

-- Step 2: 等待 autovacuum 或手动 VACUUM
VACUUM (VERBOSE, ANALYZE) fault_drill.drill_orders;

-- Step 3: 确认恢复
SELECT
    relname,
    n_live_tup,
    n_dead_tup,
    pg_size_pretty(pg_total_relation_size('fault_drill.drill_orders')) AS total_size,
    last_autovacuum
FROM pg_stat_user_tables
WHERE schemaname = 'fault_drill' AND relname = 'drill_orders';

-- Step 4: 确认无残留长事务
SELECT count(*) AS remaining_long_tx
FROM pg_stat_activity
WHERE application_name = 'fault_drill_long_tx';

-- Step 5: 清理演练数据（可选，按需执行）
-- DROP SCHEMA fault_drill CASCADE;
