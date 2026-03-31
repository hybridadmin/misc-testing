# ClickHouse Memory Limit Exceeded During AggregatingTransform

## Error

```
DB::Exception: (total) memory limit exceeded: would use 9.75 GiB
(attempt to allocate chunk of 0.00 B), current RSS: 6.29 GiB,
maximum: 7.20 GiB. OvercommitTracker decision: Query was selected
to stop by OvercommitTracker: While executing AggregatingTransform
```

Observed via `pg_stat_ch_stats()` — the PostgreSQL-to-ClickHouse exporter was hitting this during inserts.

## Root Cause

ClickHouse is trying to use ~9.75 GiB during an `AggregatingTransform` operation, but the server/query memory limit is 7.20 GiB. This happens on the **write path** — typically triggered by a materialized view, projection, or background merge.

## Fixes (in order of preference)

### 1. Increase the ClickHouse server memory limit

In `config.xml` or `users.xml`:

```xml
<!-- config.xml — raise total server memory limit -->
<max_server_memory_usage_to_ram_ratio>0.9</max_server_memory_usage_to_ram_ratio>

<!-- users.xml — raise per-query limit -->
<profiles>
  <default>
    <max_memory_usage>12000000000</max_memory_usage> <!-- ~12 GiB -->
  </default>
</profiles>
```

If running in a container, increase the container memory limit first.

### 2. Allow aggregation spill-to-disk

This is the least disruptive fix — instead of failing, ClickHouse spills to disk when memory gets tight:

```sql
ALTER USER default SETTINGS
    max_bytes_before_external_group_by = 4000000000;  -- 4 GiB threshold
```

### 3. Reduce memory pressure from aggregations

Check for materialized views on the target table:

```sql
SELECT name, as_select FROM system.tables
WHERE engine = 'MaterializedView' AND database = 'your_db';
```

Options:
- Simplify the aggregation (fewer `GROUP BY` keys, fewer columns)
- Drop or rebuild heavy materialized views

### 4. Send smaller batches from the PG client

Reduce the batch size in the PostgreSQL-to-ClickHouse exporter so each INSERT triggers a smaller merge/aggregation.

### 5. Check for part count bloat

Too many parts forces large background merges which spike memory:

```sql
SELECT table, count() AS parts
FROM system.parts
WHERE active
GROUP BY table
ORDER BY parts DESC;
```

## Diagnostic Queries

| Check | Command |
|---|---|
| Server RAM | `SELECT * FROM system.asynchronous_metrics WHERE metric LIKE '%Memory%'` |
| Active MVs | `SELECT * FROM system.tables WHERE engine = 'MaterializedView'` |
| Part count | `SELECT table, count() FROM system.parts WHERE active GROUP BY table` |
| Current limits | `SELECT * FROM system.settings WHERE name LIKE '%memory%'` |
| Running queries | `SELECT query, memory_usage, peak_memory_usage FROM system.processes ORDER BY peak_memory_usage DESC` |
