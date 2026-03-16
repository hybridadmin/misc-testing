# Reconstructing PostgreSQL Replication Setup from Database Metadata

All the information needed to reconstruct a pglogical (or native logical replication) setup is stored in queryable catalog tables within the database itself.

---

## 1. Nodes

### Query existing node configuration

```sql
SELECT node_id, node_name, if_dsn
FROM pglogical.node
JOIN pglogical.node_interface ON node_id = if_nodeid;
```

### Reconstruct node creation commands

```sql
SELECT format(
    'SELECT pglogical.create_node(node_name := %L, dsn := %L);',
    node_name, if_dsn
)
FROM pglogical.node
JOIN pglogical.node_interface ON node_id = if_nodeid;
```

---

## 2. Replication Sets

### Query replication sets

```sql
SELECT set_id, set_nodeid, set_name, replicate_insert,
       replicate_update, replicate_delete, replicate_truncate
FROM pglogical.replication_set;
```

### Query tables in each replication set

```sql
SELECT set_name, nspname, relname
FROM pglogical.replication_set_table
JOIN pglogical.replication_set USING (set_id)
JOIN pg_class ON set_reloid = oid
JOIN pg_namespace ON relnamespace = pg_namespace.oid;
```

### Reconstruct replication set creation commands

```sql
SELECT format(
    'SELECT pglogical.create_replication_set(%L, replicate_insert := %s, replicate_update := %s, replicate_delete := %s, replicate_truncate := %s);',
    set_name, replicate_insert, replicate_update, replicate_delete, replicate_truncate
)
FROM pglogical.replication_set;
```

### Reconstruct table membership commands

```sql
SELECT format(
    'SELECT pglogical.replication_set_add_table(%L, %L);',
    set_name, nspname || '.' || relname
)
FROM pglogical.replication_set_table
JOIN pglogical.replication_set USING (set_id)
JOIN pg_class ON set_reloid = oid
JOIN pg_namespace ON relnamespace = pg_namespace.oid;
```

---

## 3. Subscriptions

### Query subscriptions (on the subscriber node)

```sql
SELECT sub_id, sub_name, sub_origin, sub_origin_if,
       sub_target, sub_target_if, sub_enabled,
       sub_slot_name, sub_replication_sets
FROM pglogical.subscription;
```

### Reconstruct subscription creation commands

```sql
SELECT format(
    'SELECT pglogical.create_subscription(subscription_name := %L, provider_dsn := %L, replication_sets := %L);',
    sub_name, if_dsn, sub_replication_sets
)
FROM pglogical.subscription
JOIN pglogical.node_interface ON sub_origin_if = if_id;
```

---

## 4. Sequence Adjustments

Logical replication (including pglogical) **does not replicate sequence values** by default. When failing over or setting up a new subscriber, sequences will be out of date, leading to primary key conflicts.

### Query current sequence state on the provider

```sql
SELECT schemaname, sequencename, last_value, start_value,
       increment_by, max_value, min_value, cache_size, cycle
FROM pg_sequences;
```

### Query sequences tied to tables (SERIAL / IDENTITY columns)

```sql
SELECT
    t.relname AS table_name,
    a.attname AS column_name,
    s.relname AS sequence_name,
    pg_sequence_last_value(s.oid) AS last_value
FROM pg_class s
JOIN pg_depend d ON d.objid = s.oid
JOIN pg_class t ON d.refobjid = t.oid
JOIN pg_attribute a ON (a.attrelid = t.oid AND a.attnum = d.refobjsubid)
WHERE s.relkind = 'S';
```

### pglogical sequence synchronization

```sql
-- Synchronize all sequences in a replication set
SELECT pglogical.synchronize_sequence(seqoid)
FROM pglogical.sequence_state;

-- Add all sequences in a schema to a replication set
SELECT pglogical.replication_set_add_all_sequences(
    set_name := 'default',
    schema_names := ARRAY['public']
);

-- Check which sequences are in replication sets
SELECT set_name, nspname, relname
FROM pglogical.replication_set_seq
JOIN pglogical.replication_set USING (set_id)
JOIN pg_class ON set_seqoid = oid
JOIN pg_namespace ON relnamespace = pg_namespace.oid;
```

### Reconstruct replication set sequence membership commands

```sql
SELECT format(
    'SELECT pglogical.replication_set_add_sequence(set_name := %L, relation := %L);',
    set_name,
    nspname || '.' || relname
)
FROM pglogical.replication_set_seq
JOIN pglogical.replication_set USING (set_id)
JOIN pg_class ON set_seqoid = oid
JOIN pg_namespace ON relnamespace = pg_namespace.oid;
```

### Generate setval() commands to restore sequence values

```sql
SELECT format(
    'SELECT setval(%L, %s, true);',
    schemaname || '.' || sequencename,
    last_value
)
FROM pg_sequences
WHERE last_value IS NOT NULL;
```

### Generate setval() with a safety buffer (recommended for failover)

```sql
SELECT format(
    'SELECT setval(%L, %s, true);',
    schemaname || '.' || sequencename,
    last_value + 1000
)
FROM pg_sequences
WHERE last_value IS NOT NULL;
```

---

## 5. Native Logical Replication (PostgreSQL 10+)

If using built-in logical replication instead of pglogical:

```sql
-- Publications (on publisher)
SELECT * FROM pg_publication;
SELECT * FROM pg_publication_tables;

-- Subscriptions (on subscriber)
SELECT * FROM pg_subscription;
```

---

## Notes

- **All metadata is in the `pglogical` schema** (or `pg_catalog` for native replication) and is queryable with standard SQL.
- **DSN strings** are stored in `pglogical.node_interface`, so connection info can be recovered.
- **Replication set membership** (which tables and sequences are in which sets) is stored and queryable.
- **Credentials caveat**: DSN strings may be partial or omitted if `.pgpass` or environment variables were used instead of inline passwords.
- **Sequences are NOT replicated automatically** in logical replication -- this is a common source of duplicate key errors after failover.
- **pglogical can track sequences** if explicitly added to replication sets, but the sync is periodic, not real-time.
- **Always add a buffer** when restoring sequence values to a new primary to avoid conflicts from in-flight transactions.
