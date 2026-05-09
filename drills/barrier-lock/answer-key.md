# 标准答案: 备份卡住导致 BarrierLock 等待

> 此文件是出题人用的评判标准, 不要给 SRE 看

## 故障链路

```
pg_start_backup() 调用后未完成 (模拟备份进程卡死)
  → 持有 ExclusiveBackupLock / BarrierLock
    → CHECKPOINT / DDL / VACUUM 等操作排队等锁
      → 间接阻塞业务 SQL (锁队列级联)
        → 业务响应间歇性卡顿
```

## 关键特征 — SRE 应该注意到的

与死元组不同, barrier lock 导致的慢有明显特征:
- **间歇性** — 不是所有查询都慢, 是偶尔卡住几秒
- **DDL 卡死** — CHECKPOINT / ALTER TABLE 等操作 hang 住
- **wait_event** — pg_stat_activity 中能看到 BarrierLock 或 BackupLock

## SRE 应该怎么定位

### 第一步: 看活跃会话和等待事件

```sql
-- 这是关键命令 — 看谁在等什么锁
SELECT
    pid,
    state,
    wait_event_type,
    wait_event,
    now() - query_start AS wait_duration,
    application_name,
    left(query, 80) AS query
FROM pg_stat_activity
WHERE wait_event IS NOT NULL
  AND state = 'active'
ORDER BY query_start;
```

SRE 应该看到:
- 多个会话 wait_event 显示 `BarrierLock` 或 `BackupLock`
- 这些会话的 query 是 CHECKPOINT / DDL 类操作
- 它们的 wait_duration 持续增长

### 第二步: 检查备份状态

```sql
-- 是不是有备份在跑?
SELECT pg_is_in_backup();

-- 如果是 true, 找到备份会话
SELECT
    pid,
    state,
    application_name,
    now() - xact_start AS duration,
    left(query, 80) AS query
FROM pg_stat_activity
WHERE query LIKE '%backup%'
   OR application_name LIKE '%backup%'
ORDER BY xact_start;
```

### 第三步: 确认因果关系

```sql
-- 看锁等待链: 谁阻塞了谁
SELECT
    blocked.pid     AS blocked_pid,
    blocked.query   AS blocked_query,
    blocker.pid     AS blocker_pid,
    blocker.query   AS blocker_query,
    blocker.application_name AS blocker_app
FROM pg_stat_activity blocked
JOIN pg_locks bl ON bl.pid = blocked.pid
JOIN pg_locks bk ON bk.locktype = bl.locktype
  AND bk.granted = true AND bl.granted = false
JOIN pg_stat_activity blocker ON blocker.pid = bk.pid
WHERE blocked.pid <> blocker.pid;
```

## SRE 应该怎么恢复

### 第一步: 停止卡住的备份

```sql
-- 方法 1: 正常停止备份
SELECT pg_stop_backup();

-- 方法 2: 如果方法 1 不行, 杀备份会话
SELECT pg_terminate_backend(<备份会话的pid>);
```

### 第二步: 验证恢复

```sql
-- 确认备份状态已解除
SELECT pg_is_in_backup();  -- 应该返回 false

-- 确认没有等锁的会话了
SELECT count(*) FROM pg_stat_activity
WHERE wait_event IS NOT NULL AND state = 'active';

-- 确认业务查询恢复正常
-- (看 inject.sh 的 WORKLOAD 日志, 耗时应该降回基线)
```

## 评判标准

| 级别 | 标准 | 时间参考 |
|------|------|---------|
| 优秀 | 通过 wait_event 直接看到 BarrierLock, 查到备份卡住, pg_stop_backup 恢复 | < 5 min |
| 合格 | 能发现等锁, 但花时间找 blocker, 最终通过杀进程恢复 | < 15 min |
| 待提升 | 只看到 SQL 慢, 没查 wait_event, 或者不知道怎么停备份 | > 15 min |

## 常见误区

| SRE 做了什么 | 问题 |
|-------------|------|
| 看 CPU / IO / 死元组 | 资源层都正常, 问题在锁层面 |
| 只杀了被阻塞的 DDL | 杀错了! 要杀的是持锁的备份会话 |
| 重启数据库 | 能解决但太暴力, 应该先尝试 pg_stop_backup |
| 等它自己好 | 备份不会自己停, 会一直卡 |

## 与死元组场景的对比

| 维度 | 死元组积压 | BarrierLock |
|------|-----------|-------------|
| 慢的模式 | 持续变慢, 越来越差 | 间歇性卡顿, 时好时坏 |
| 影响范围 | 只影响特定表 | 影响 DDL + 间接影响 DML |
| 定位路径 | pg_stat_user_tables → 长事务 | wait_event → 备份状态 |
| 恢复手段 | kill 长事务 + VACUUM | pg_stop_backup 或杀备份进程 |
| 恢复速度 | 需要 VACUUM 时间 | 秒级恢复 |
