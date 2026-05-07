# 标准答案: 死元组积压导致 SQL 整体变慢

> 此文件是出题人用的评判标准, 不要给 SRE 看

## 故障链路

```
长事务 (持有 REPEATABLE READ 快照)
  → 阻止 autovacuum 回收死元组
    → n_dead_tup 持续增长, 表膨胀
      → 优化器代价估算失准, Seq Scan 增多
        → 查询计划变差, SQL 整体变慢
```

## SRE 应该怎么定位

### 第一步: 发现 SQL 变慢 — 看现场

SRE 应该先确认"慢在哪"：

```sql
-- 看当前活跃慢查询
SELECT pid, now() - query_start AS duration, left(query, 100) AS query
FROM pg_stat_activity
WHERE state = 'active'
  AND now() - query_start > interval '3 seconds'
ORDER BY duration DESC;
```

### 第二步: 看计划是否变差

```sql
-- 对变慢的查询跑 EXPLAIN, 关注:
--   Seq Scan 代替了 Index Scan?
--   估算行数 vs 实际行数差距大?
--   cost 比正常高很多?
EXPLAIN ANALYZE
SELECT region, count(*), avg(amount)
FROM fault_drill.drill_orders
WHERE status = 'pending'
GROUP BY region;
```

### 第三步: 检查表膨胀和死元组 (关键一步)

```sql
-- 这是核心诊断命令 — 直接暴露根因
SELECT
    schemaname,
    relname,
    n_live_tup,
    n_dead_tup,
    round(n_dead_tup::numeric / greatest(n_live_tup, 1) * 100, 1) AS dead_pct,
    last_autovacuum,
    last_autoanalyze
FROM pg_stat_user_tables
WHERE n_dead_tup > 10000
ORDER BY n_dead_tup DESC;
```

看到 `dead_pct` 很高且 `last_autovacuum` 很久没跑, SRE 应该意识到:
死元组堆积 + autovacuum 没清理 → 有东西在阻塞 vacuum

### 第四步: 找到阻塞 autovacuum 的长事务

```sql
-- 找长事务 (注意: 不一定是 idle in transaction, 也可能是 active 状态)
SELECT
    pid,
    usename,
    application_name,
    state,
    now() - xact_start AS tx_duration,
    now() - query_start AS query_duration,
    left(query, 80) AS query_preview
FROM pg_stat_activity
WHERE now() - xact_start > interval '5 minutes'
ORDER BY xact_start;
```

到这一步, SRE 应该能看到 `fault_drill_long_tx` 这个会话已经跑了很久,
就是它 hold 住了旧快照, 导致 autovacuum 无法回收死元组。

## SRE 应该怎么恢复

### 第一步: 终止长事务

```sql
-- 先确认 pid, 再杀
SELECT pg_terminate_backend(<pid>);
```

### 第二步: 手动 VACUUM

```sql
-- 长事务杀掉后, autovacuum 会自动跑, 但手动更快
VACUUM ANALYZE fault_drill.drill_orders;
```

### 第三步: 验证恢复

```sql
-- 死元组应该降到接近 0
SELECT n_dead_tup FROM pg_stat_user_tables
WHERE schemaname = 'fault_drill' AND relname = 'drill_orders';

-- 查询耗时应该恢复到基线水平
-- (看 inject.sh 的 WORKLOAD 日志, 倍率应该降回 1.x)
```

如果 SRE 做对了, inject.sh 会自动检测到恢复并打印 "SRE 演练成功!"

## 评判标准

| 级别 | 标准 | 时间参考 |
|------|------|---------|
| 优秀 | 直接查 pg_stat_user_tables 定位死元组, 再查长事务, 一条链路走通 | < 10 min |
| 合格 | 能定位但绕了弯路 (先看 CPU/IO/锁/网络等再回到死元组) | < 20 min |
| 待提升 | 只发现 SQL 慢, 但没查到死元组或没找到长事务 | > 20 min |

## 常见误区

| SRE 做了什么 | 问题 |
|-------------|------|
| 只看 CPU/IO/内存 | 资源层面可能没异常, 问题在数据库内部 |
| 看到慢查询就加索引 | 索引已经有了, 是死元组导致估算偏差 |
| 杀了长事务但没 VACUUM | autovacuum 最终会跑, 但恢复慢 |
| VACUUM 了但没杀长事务 | 长事务还在, vacuum 无法回收, 白跑 |
