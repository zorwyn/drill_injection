\set ON_ERROR_STOP on
\pset pager off
\timing on

CREATE SCHEMA IF NOT EXISTS :"schema_name";
SET search_path TO :"schema_name", public;

CREATE TABLE IF NOT EXISTS orders_hot (
    order_id bigint PRIMARY KEY,
    tenant_id integer NOT NULL,
    customer_id bigint NOT NULL,
    status char(1) NOT NULL,
    region_id integer NOT NULL,
    amount numeric(18, 2) NOT NULL,
    created_at timestamp NOT NULL,
    updated_at timestamp NOT NULL,
    filler text NOT NULL
);

CREATE TABLE IF NOT EXISTS order_items_hot (
    item_id bigint PRIMARY KEY,
    order_id bigint NOT NULL,
    sku_id bigint NOT NULL,
    qty integer NOT NULL,
    price numeric(18, 2) NOT NULL,
    updated_at timestamp NOT NULL,
    filler text NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_orders_hot_tenant_status_created
    ON orders_hot (tenant_id, status, created_at);

CREATE INDEX IF NOT EXISTS idx_orders_hot_customer
    ON orders_hot (customer_id);

CREATE INDEX IF NOT EXISTS idx_order_items_hot_order
    ON order_items_hot (order_id);

CREATE INDEX IF NOT EXISTS idx_order_items_hot_sku
    ON order_items_hot (sku_id);

INSERT INTO orders_hot (
    order_id,
    tenant_id,
    customer_id,
    status,
    region_id,
    amount,
    created_at,
    updated_at,
    filler
)
SELECT
    gs,
    ((gs - 1) % :tenant_mod) + 1,
    gs * 10,
    CASE
        WHEN gs % 10 < 6 THEN 'P'
        WHEN gs % 10 < 9 THEN 'S'
        ELSE 'C'
    END,
    ((gs - 1) % 32) + 1,
    ((gs % 100000) * 0.13)::numeric(18, 2),
    clock_timestamp() - ((gs % 432000) || ' seconds')::interval,
    clock_timestamp() - ((gs % 86400) || ' seconds')::interval,
    repeat('x', :payload_width)
FROM generate_series(1, :seed_rows) AS gs
WHERE NOT EXISTS (
    SELECT 1
    FROM orders_hot
    LIMIT 1
);

INSERT INTO order_items_hot (
    item_id,
    order_id,
    sku_id,
    qty,
    price,
    updated_at,
    filler
)
SELECT
    gs,
    ((gs - 1) / :items_per_order) + 1,
    ((gs - 1) % 200000) + 1,
    (gs % 7) + 1,
    ((gs % 10000) * 0.07)::numeric(18, 2),
    clock_timestamp() - ((gs % 86400) || ' seconds')::interval,
    repeat('y', :item_payload_width)
FROM generate_series(1, (:seed_rows * :items_per_order)) AS gs
WHERE NOT EXISTS (
    SELECT 1
    FROM order_items_hot
    LIMIT 1
);

ANALYZE orders_hot;
ANALYZE order_items_hot;

SELECT
    clock_timestamp() AS sampled_at,
    count(*) AS order_rows,
    min(order_id) AS min_order_id,
    max(order_id) AS max_order_id
FROM orders_hot;

SELECT
    clock_timestamp() AS sampled_at,
    count(*) AS item_rows
FROM order_items_hot;
