# 标准答案: 分布式数据分布不均衡导致 SQL 整体变慢

> 此文件是出题人用的评判标准, 不要给 SRE 看

## 故障链路

```
分布列选错 (status, 低基数, 5 个值)
  → hash(status) 把 90%+ 数据路由到 1 个 DN
    → 3 个 DN 数据量极不均衡 (倾斜 DN 是其他 9~30 倍)
      → 聚合 / JOIN / 全表扫描时, 倾斜 DN 成瓶颈, 其他 DN 空等
        → 整体 SQL 整体变慢 (尤其 OLAP 类查询)
```

## 关键特征 — SRE 应该注意到的

与死元组 / barrier lock 都不同, 数据倾斜的特征:
- **聚合/JOIN 慢, 点查正常** — 单 DN 处理点查无压力, 但全表聚合被倾斜 DN 拖
- **EXPLAIN PERFORMANCE 看 DN 间执行时间差异巨大** — 倾斜 DN 远慢于其他
- **CPU/IO 单 DN 偏高** — 监控会显示某个 DN 资源持续高
- **不会自愈** — 死元组能 VACUUM, 锁能释放, 倾斜需要重建表才能修

## SRE 应该怎么定位

### 第一步: 看慢查询特征 — 是不是聚合/JOIN 类

```sql
-- 看现在的活跃慢查询
SELECT pid, now() - query_start AS duration,
       state, left(query, 100) AS query
FROM pg_stat_activity
WHERE state = 'active'
  AND now() - query_start > interval '2 seconds'
ORDER BY duration DESC;
```

如果慢的都是 `count(*)` / `GROUP BY` / `JOIN` 类 SQL, 而点查 (WHERE id=X) 没问题,
就要怀疑分布层面的问题。

### 第二步: 看 EXPLAIN PERFORMANCE — DN 间执行时间是否对称

```sql
EXPLAIN PERFORMANCE
SELECT count(*) FROM fault_drill.drill_skew;
```

GaussDB 的 EXPLAIN PERFORMANCE 会输出每个 DN 的执行时间,
**正常情况各 DN 时间接近, 倾斜时一个 DN 远大于其他**。

### 第三步: 直接查倾斜度 (关键命令)

```sql
-- 这是核心诊断命令 — 直接给出每个 DN 的行数
SELECT * FROM pgxc_get_table_skewness('fault_drill.drill_skew');
```

或者用 pgxc_node_id 隐藏列 (兼容性更好):

```sql
SELECT pgxc_node_id, count(*) AS rows,
       round(100.0 * count(*) / sum(count(*)) OVER (), 1) AS pct
FROM fault_drill.drill_skew
GROUP BY pgxc_node_id
ORDER BY rows DESC;
```

应该看到一个 DN 占 90%+, 另外两个 DN 各占 5% 左右。这就是倾斜的实锤。

### 第四步: 看分布键定义 — 找根因

```sql
-- 看表的分布键
SELECT pg_get_tabledef('fault_drill.drill_skew');
```

会看到 `DISTRIBUTE BY HASH(status)`。结合业务知识或简单统计就能反应过来:
status 列只有 5 个值, 选它做分布键必然倾斜。

```sql
-- 验证: 看 status 列各值的占比
SELECT status, count(*),
       round(100.0 * count(*) / sum(count(*)) OVER (), 1) AS pct
FROM fault_drill.drill_skew
GROUP BY status;
```

## SRE 应该怎么恢复

倾斜没法"在线修复", 必须重建表换分布键。

### 方法 1: 重建表 + 重新插入 (推荐)

```sql
-- 1) 创建修复版表, 用高基数列 id 做分布键
CREATE TABLE fault_drill.drill_skew_fixed (
    LIKE fault_drill.drill_skew INCLUDING ALL
) DISTRIBUTE BY HASH(id);

-- 2) 把数据搬过去
INSERT INTO fault_drill.drill_skew_fixed
SELECT * FROM fault_drill.drill_skew;

-- 3) ANALYZE
ANALYZE fault_drill.drill_skew_fixed;

-- 4) 验证: 各 DN 是否均衡
SELECT * FROM pgxc_get_table_skewness('fault_drill.drill_skew_fixed');

-- 5) 业务侧切换 (生产: 改连接配置或表名, 演练里建好 _fixed 表即可)
-- ALTER TABLE fault_drill.drill_skew RENAME TO drill_skew_old;
-- ALTER TABLE fault_drill.drill_skew_fixed RENAME TO drill_skew;
```

> 演练判定: 一旦 SRE 建好 `drill_skew_fixed` 表, inject.sh 会自动检测并结束演练。

### 方法 2: 选用更合适的分布列

不是所有高基数列都适合做分布列, 要考虑:
- **基数足够高** — 至少远大于 DN 数 (3 DN 时, 基数 ≥ 数百)
- **分布均匀** — 没有热点值
- **常用 JOIN 键** — 同 JOIN 键的两表用相同分布列, 可避免 redistribute
- **不要选 boolean / status / type 这类枚举列**

### 方法 3: 改用 REPLICATION (仅适合小表)

对于维度表 (行数 < 1万), 可以:
```sql
... DISTRIBUTE BY REPLICATION;
```
每个 DN 都存全量, JOIN 时不需要 redistribute, 适合小表。

## 评判标准

| 级别 | 标准 | 时间参考 |
|------|------|---------|
| 优秀 | 通过 EXPLAIN PERFORMANCE 或 pgxc_get_table_skewness 直接定位倾斜, 重建表恢复 | < 10 min |
| 合格 | 怀疑到分布问题, 通过 pgxc_node_id 查询定位, 给出修复方案 | < 20 min |
| 待提升 | 只看到聚合慢, 怀疑是计划/索引/CPU 问题, 没查到分布层面 | > 20 min |

## 常见误区

| SRE 做了什么 | 问题 |
|-------------|------|
| 看 CPU / 内存 / IO 整体 | 整体可能正常, 单 DN 高才是关键, 要按节点维度看 |
| 加索引 | 索引解决不了倾斜, 反而让单 DN 更忙 |
| VACUUM / ANALYZE | 没用, 不是统计信息问题 |
| 看 pg_stat_user_tables | 这是单节点视图, 看不出分布问题 |
| 调整 work_mem / shared_buffers | 治标不治本 |
| 等它自己好 | 倾斜是结构性问题, 不会自愈, 必须重建 |

## 与前两个场景的对比

| 维度 | 死元组积压 | BarrierLock | 数据倾斜 |
|------|-----------|-------------|---------|
| 慢的模式 | 持续变慢 | 间歇性卡顿 | 整体偏慢 (聚合/JOIN 尤其) |
| 影响范围 | 单表 | DDL + 间接 DML | 单表的所有跨 DN 操作 |
| 单 DN vs 全 DN | N/A | N/A | **单 DN CPU/IO 高, 其他空闲** |
| 定位路径 | pg_stat_user_tables → 长事务 | wait_event → 备份状态 | EXPLAIN PERFORMANCE → pgxc_get_table_skewness |
| 关键诊断命令 | `n_dead_tup` | `pg_locks granted=false` | `pgxc_get_table_skewness()` |
| 恢复手段 | kill 长事务 + VACUUM | 杀持锁会话 | **重建表换分布键** |
| 恢复速度 | 秒级 | 秒级 | 分钟级 (取决于表大小) |
| 是否自愈 | 部分 (autovacuum) | 否 | **完全不会** |
