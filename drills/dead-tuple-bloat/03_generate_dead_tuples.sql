-- Phase 2: 批量 UPDATE 产生死元组
-- 在另一个会话中执行，每轮更新 200000 行，共 5 轮
-- 由于 Phase 1 的长事务持有旧快照，这些旧版本行无法被回收

-- 第 1 轮：更新 status 字段
UPDATE fault_drill.drill_orders
SET status = 'processing', updated_at = now()
WHERE id IN (SELECT id FROM fault_drill.drill_orders ORDER BY id LIMIT 200000);

SELECT 'round_1_done' AS phase,
       n_dead_tup, n_live_tup
FROM pg_stat_user_tables
WHERE schemaname = 'fault_drill' AND relname = 'drill_orders';

-- 第 2 轮：更新 amount 字段
UPDATE fault_drill.drill_orders
SET amount = amount + 0.01, updated_at = now()
WHERE id IN (SELECT id FROM fault_drill.drill_orders ORDER BY id LIMIT 200000);

SELECT 'round_2_done' AS phase,
       n_dead_tup, n_live_tup
FROM pg_stat_user_tables
WHERE schemaname = 'fault_drill' AND relname = 'drill_orders';

-- 第 3 轮：更新 region 字段
UPDATE fault_drill.drill_orders
SET region = 'drill_' || region, updated_at = now()
WHERE id IN (SELECT id FROM fault_drill.drill_orders ORDER BY id LIMIT 200000);

SELECT 'round_3_done' AS phase,
       n_dead_tup, n_live_tup
FROM pg_stat_user_tables
WHERE schemaname = 'fault_drill' AND relname = 'drill_orders';

-- 第 4 轮
UPDATE fault_drill.drill_orders
SET status = 'review', updated_at = now()
WHERE id IN (SELECT id FROM fault_drill.drill_orders ORDER BY random() LIMIT 200000);

SELECT 'round_4_done' AS phase,
       n_dead_tup, n_live_tup
FROM pg_stat_user_tables
WHERE schemaname = 'fault_drill' AND relname = 'drill_orders';

-- 第 5 轮
UPDATE fault_drill.drill_orders
SET amount = amount - 0.01, updated_at = now()
WHERE id IN (SELECT id FROM fault_drill.drill_orders ORDER BY random() LIMIT 200000);

SELECT 'round_5_done' AS phase,
       n_dead_tup, n_live_tup
FROM pg_stat_user_tables
WHERE schemaname = 'fault_drill' AND relname = 'drill_orders';
