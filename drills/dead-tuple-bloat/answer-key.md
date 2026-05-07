# 标准答案: 死元组积压导致 SQL 整体变慢

## 故障链路

```
长事务 (idle in transaction)
  → 阻止 autovacuum 回收死元组
    → n_dead_tup 持续增长, 表膨胀
      → 优化器代价估算失准
        → 查询计划变差, SQL 整体变慢
```

## SRE 应该怎么定位

### 第一步: 发现 SQL 变慢

```sql
-- 查看当前活跃慢查询
SELECT pid, now()-query_start AS duration, query
FROM pg_stat_activity
WHERE state = 'active'
  AND now()-query_start > interval '5 seconds'
ORDER BY duration DESC;
```

### 第二步: 看计划是否变差

```sql
-- 对比慢查询的 EXPLAIN, 看 cost 和实际行数估算
EXPLAIN ANALYZE <slow_query>;

-- 关注: Seq Scan 代替了 Index Scan? 估算行数 vs 实际行数差距大?
```

### 第三步: 检查表膨胀和死元组

```sql
-- 核心诊断命令
SELECT
    schemaname,
    relname,
    n_live_tup,
    n_dead_tup,
    round(n_dead_tup::numeric / greatest(n_live_tup, 1) * 100, 1) AS dead_ratio_pct,
    last_autovacuum,
    last_autoanalyze
FROM pg_stat_user_tables
WHERE n_dead_tup > 10000
ORDER BY n_dead_tup DESC;
```

### 第四步: 找到阻塞 autovacuum 的长事务

```sql
-- 找长事务
SELECT
    pid,
    usename,
    application_name,
    state,
    now() - xact_start AS tx_duration,
    now() - query_start AS query_duration,
    left(query, 80) AS query_preview
FROM pg_stat_activity
WHERE state = 'idle in transaction'
  AND now() - xact_start > interval '5 minutes'
ORDER BY xact_start;

-- 看 xmin 年龄 (长事务会 pin 住旧快照)
SELECT
    pid,
    backend_xmin,
    age(backend_xmin) AS xmin_age,
    now() - xact_start AS duration
FROM pg_stat_activity
WHERE backend_xmin IS NOT NULL
ORDER BY age(backend_xmin) DESC
LIMIT 5;
```

## SRE 应该怎么恢复

### 第一步: 终止长事务

```sql
-- 先确认再杀
SELECT pg_terminate_backend(<pid>);
```

### 第二步: 手动 VACUUM

```sql
-- 等 autovacuum 自己跑也行, 但手动更快
VACUUM ANALYZE <schema>.<table>;
```

### 第三步: 验证恢复

```sql
-- 确认死元组下降
SELECT n_dead_tup FROM pg_stat_user_tables
WHERE schemaname = '<schema>' AND relname = '<table>';

-- 确认计划恢复
EXPLAIN ANALYZE <之前变慢的查询>;
```

## 评判标准

| 级别 | 标准 | 时间参考 |
|------|------|---------|
| 优秀 | 直接从 pg_stat_user_tables 定位到死元组 + 长事务 | < 10 min |
| 合格 | 能定位但绕了弯路 (先看 CPU/IO/锁等) | < 20 min |
| 待提升 | 只发现 SQL 慢但没找到根因 | > 20 min |
