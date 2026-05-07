\set ON_ERROR_STOP on
\pset pager off
\timing on

SET application_name TO 'drill-query-probe';
SET search_path TO :"schema_name", public;

EXPLAIN (ANALYZE, COSTS, VERBOSE)
SELECT
    o.tenant_id,
    o.status,
    count(*) AS order_cnt,
    sum(o.amount) AS total_amount
FROM orders_hot o
WHERE o.tenant_id = :tenant_id
  AND o.status = 'P'
  AND o.created_at >= clock_timestamp() - (:lookback_minutes || ' minutes')::interval
GROUP BY o.tenant_id, o.status;

EXPLAIN (ANALYZE, COSTS, VERBOSE)
SELECT
    o.order_id,
    o.customer_id,
    sum(i.qty * i.price) AS gross_amount
FROM orders_hot o
JOIN order_items_hot i
  ON i.order_id = o.order_id
WHERE o.tenant_id = :tenant_id
  AND o.status = 'S'
  AND o.created_at >= clock_timestamp() - (:lookback_minutes || ' minutes')::interval
GROUP BY o.order_id, o.customer_id
ORDER BY gross_amount DESC
LIMIT :topn;

SELECT
    clock_timestamp() AS sampled_at,
    count(*) AS probe_active_rows
FROM orders_hot
WHERE tenant_id = :tenant_id
  AND status IN ('P', 'S');
