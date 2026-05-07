\set ON_ERROR_STOP on
\pset pager off
\timing on

SET application_name TO 'drill-observe';
SET search_path TO :"schema_name", public;

SELECT
    clock_timestamp() AS sampled_at,
    schemaname,
    relname,
    n_live_tup,
    n_dead_tup,
    vacuum_count,
    autovacuum_count,
    analyze_count,
    autoanalyze_count
FROM pg_stat_user_tables
WHERE schemaname = :'schema_name'
  AND relname IN ('orders_hot', 'order_items_hot')
ORDER BY relname;

SELECT
    clock_timestamp() AS sampled_at,
    c.relname,
    pg_size_pretty(pg_relation_size(c.oid)) AS table_size,
    pg_size_pretty(pg_indexes_size(c.oid)) AS index_size,
    pg_size_pretty(pg_total_relation_size(c.oid)) AS total_size
FROM pg_class c
JOIN pg_namespace n
  ON n.oid = c.relnamespace
WHERE n.nspname = :'schema_name'
  AND c.relname IN ('orders_hot', 'order_items_hot')
ORDER BY c.relname;

SELECT
    clock_timestamp() AS sampled_at,
    pid,
    application_name,
    state,
    backend_xmin,
    now() - xact_start AS xact_age
FROM pg_stat_activity
WHERE application_name IN (
    'drill-long-txn',
    'drill-dml-churn',
    'drill-query-probe',
    'drill-observe'
)
ORDER BY xact_start NULLS LAST;
