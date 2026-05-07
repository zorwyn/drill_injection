-- Phase 0: 创建演练 schema 和种子数据
-- 使用独立 schema 隔离影响，演练结束后可整体清理

CREATE SCHEMA IF NOT EXISTS fault_drill;

DROP TABLE IF EXISTS fault_drill.drill_orders;

CREATE TABLE fault_drill.drill_orders (
    id          BIGSERIAL PRIMARY KEY,
    user_id     INT       NOT NULL,
    amount      NUMERIC(12,2) NOT NULL,
    status      VARCHAR(20)   NOT NULL DEFAULT 'pending',
    region      VARCHAR(10)   NOT NULL,
    created_at  TIMESTAMP     NOT NULL DEFAULT now(),
    updated_at  TIMESTAMP     NOT NULL DEFAULT now(),
    padding     VARCHAR(200)  NOT NULL DEFAULT repeat('x', 200)
);

CREATE INDEX idx_drill_orders_status ON fault_drill.drill_orders(status);
CREATE INDEX idx_drill_orders_user   ON fault_drill.drill_orders(user_id);
CREATE INDEX idx_drill_orders_region ON fault_drill.drill_orders(region);

INSERT INTO fault_drill.drill_orders (user_id, amount, status, region)
SELECT
    (random() * 10000)::INT,
    (random() * 9999 + 1)::NUMERIC(12,2),
    (ARRAY['pending','paid','shipped','done','cancelled'])[floor(random()*5+1)::INT],
    (ARRAY['east','west','north','south','central'])[floor(random()*5+1)::INT]
FROM generate_series(1, 500000);

ANALYZE fault_drill.drill_orders;

-- 记录基线
SELECT
    relname,
    n_live_tup,
    n_dead_tup,
    last_autovacuum,
    last_autoanalyze
FROM pg_stat_user_tables
WHERE schemaname = 'fault_drill' AND relname = 'drill_orders';
