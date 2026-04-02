-- Custom pgbench read-heavy workload
-- Simulates typical application read patterns

-- Random point lookup on pgbench_accounts
\set aid random(1, 100000 * :scale)
SELECT abalance FROM pgbench_accounts WHERE aid = :aid;

-- Range scan with aggregation
\set aid_start random(1, 90000 * :scale)
SELECT count(*), avg(abalance) FROM pgbench_accounts WHERE aid BETWEEN :aid_start AND :aid_start + 100;

-- Lookup on pgbench_branches
\set bid random(1, 1 * :scale)
SELECT bbalance FROM pgbench_branches WHERE bid = :bid;

-- Lookup on pgbench_tellers
\set tid random(1, 10 * :scale)
SELECT tbalance FROM pgbench_tellers WHERE tid = :tid;

-- History scan (recent entries)
SELECT count(*) FROM pgbench_history WHERE mtime > now() - interval '5 minutes';
