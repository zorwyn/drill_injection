\set ON_ERROR_STOP on
\pset pager off
\timing on

SET application_name TO 'drill-cleanup';
SET search_path TO :"schema_name", public;

SELECT
    pg_terminate_backend(pid) AS terminated,
    pid,
    application_name
FROM pg_stat_activity
WHERE application_name IN (
    'drill-long-txn',
    'drill-dml-churn',
    'drill-query-probe',
    'drill-observe'
)
  AND pid <> pg_backend_pid();

VACUUM ANALYZE orders_hot;
VACUUM ANALYZE order_items_hot;

SELECT
    clock_timestamp() AS sampled_at,
    schemaname,
    relname,
    n_live_tup,
    n_dead_tup
FROM pg_stat_user_tables
WHERE schemaname = :'schema_name'
  AND relname IN ('orders_hot', 'order_items_hot')
ORDER BY relname;
