\set ON_ERROR_STOP on
\pset pager off
\timing on

SET application_name TO 'drill-long-txn';
SET search_path TO :"schema_name", public;

BEGIN;
SET TRANSACTION ISOLATION LEVEL REPEATABLE READ;

SELECT
    pg_backend_pid() AS holding_pid,
    txid_current() AS holding_txid,
    clock_timestamp() AS holding_started_at;

SELECT
    count(*) AS pinned_rows
FROM orders_hot
WHERE tenant_id = :tenant_id
  AND status IN ('P', 'S');

SELECT pg_sleep(:txn_hold_sec);

COMMIT;

SELECT
    clock_timestamp() AS released_at,
    pg_backend_pid() AS released_pid;
