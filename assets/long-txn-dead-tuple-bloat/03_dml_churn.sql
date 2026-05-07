\set ON_ERROR_STOP on
\pset pager off
\timing on

SET application_name TO 'drill-dml-churn';
SET search_path TO :"schema_name", public;

DO $drill$
DECLARE
    i integer;
    offset_rows bigint;
BEGIN
    FOR i IN 1..:churn_rounds LOOP
        offset_rows := ((i - 1) * :update_batch) % GREATEST(:seed_rows - :update_batch, 1);

        WITH target_orders AS (
            SELECT ctid
            FROM orders_hot
            WHERE tenant_id = :tenant_id
            ORDER BY order_id
            LIMIT :update_batch
            OFFSET offset_rows
        )
        UPDATE orders_hot o
           SET status = CASE
                            WHEN o.status = 'P' THEN 'S'
                            WHEN o.status = 'S' THEN 'P'
                            ELSE 'P'
                        END,
               amount = o.amount + ((i % 11) * 0.73)::numeric(18, 2),
               updated_at = clock_timestamp(),
               filler = repeat(substr(md5(o.order_id::text || i::text), 1, 1), :payload_width)
          FROM target_orders t
         WHERE o.ctid = t.ctid;

        WITH target_order_ids AS (
            SELECT order_id
            FROM orders_hot
            WHERE tenant_id = :tenant_id
            ORDER BY order_id
            LIMIT :item_update_batch
            OFFSET offset_rows
        )
        UPDATE order_items_hot i2
           SET qty = CASE
                         WHEN i2.qty >= 9 THEN 1
                         ELSE i2.qty + 1
                     END,
               price = i2.price + 0.05,
               updated_at = clock_timestamp(),
               filler = repeat(substr(md5(i2.item_id::text || i::text), 1, 1), :item_payload_width)
         WHERE i2.order_id IN (
             SELECT order_id
             FROM target_order_ids
         );

        PERFORM pg_sleep(:sleep_ms / 1000.0);
    END LOOP;
END
$drill$;

SELECT
    clock_timestamp() AS churn_finished_at,
    :churn_rounds AS churn_rounds_done,
    :update_batch AS order_update_batch,
    :item_update_batch AS item_update_batch;
