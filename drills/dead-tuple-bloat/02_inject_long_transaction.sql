-- Phase 1: 注入长事务
-- 此会话开启事务后执行一次查询以获取快照，然后保持不提交
-- 这会阻止 autovacuum 回收此快照之后产生的死元组
--
-- !! 此脚本需要在独立会话中运行并保持连接 !!
-- !! 不要关闭此会话，直到演练结束 !!

BEGIN;

SET application_name = 'fault_drill_long_tx';

-- 获取快照，锚定 xmin
SELECT count(*) FROM fault_drill.drill_orders WHERE status = 'pending';

-- 记录事务信息用于后续追踪和清理
SELECT
    pg_backend_pid()            AS holder_pid,
    txid_current()              AS holder_xid,
    now()                       AS started_at,
    current_setting('application_name') AS app_name;

-- ===== 保持此会话打开，不要 COMMIT 或 ROLLBACK =====
-- 演练脚本会通过 pg_terminate_backend 来结束此会话
