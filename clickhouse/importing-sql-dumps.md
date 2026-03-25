# Importing SQL Dumps into ClickHouse via CLI

## Using `clickhouse-client`

### SQL statements (INSERT, CREATE TABLE, etc.)

```bash
clickhouse-client --query "$(cat dump.sql)"
```

Or pipe it directly:

```bash
cat dump.sql | clickhouse-client --multiquery
```

The `--multiquery` flag allows executing multiple statements separated by semicolons in a single invocation.

### With connection parameters

```bash
cat dump.sql | clickhouse-client \
  --host=localhost \
  --port=9000 \
  --user=default \
  --password=secret \
  --database=mydb \
  --multiquery
```

## For CSV/TSV data dumps

If the dump is raw data rather than SQL:

```bash
# CSV
clickhouse-client --query "INSERT INTO my_table FORMAT CSV" < data.csv

# TSV
clickhouse-client --query "INSERT INTO my_table FORMAT TSV" < data.tsv

# JSONEachRow
clickhouse-client --query "INSERT INTO my_table FORMAT JSONEachRow" < data.json
```

## For large dumps

For very large files, these options help:

```bash
cat dump.sql | clickhouse-client \
  --multiquery \
  --max_insert_block_size=1000000 \
  --max_memory_usage=10000000000
```

Or split schema and data:

```bash
# 1. Import schema first
clickhouse-client --multiquery < schema.sql

# 2. Then import data
clickhouse-client --query "INSERT INTO my_table FORMAT Native" < data.native
```

## Tips

- **`--multiquery`** is the most important flag for SQL dumps with multiple statements.
- **Native format** is the fastest for ClickHouse-to-ClickHouse transfers. Export with:
  ```bash
  clickhouse-client --query "SELECT * FROM t FORMAT Native" > dump.native
  ```
- If importing from MySQL/PostgreSQL dumps, the SQL syntax will likely need adapting (different data types, no `AUTO_INCREMENT`, etc.).
- For compressed dumps:
  ```bash
  zcat dump.sql.gz | clickhouse-client --multiquery
  ```

---

# Creating an Insert-Only User in ClickHouse

## Via SQL (simplest)

```sql
-- Create user with no password
CREATE USER insert_user NO PASSWORD;

-- Grant only INSERT on a specific database
GRANT INSERT ON my_database.* TO insert_user;
```

The user can only INSERT into tables in `my_database` and nothing else (no SELECT, no DDL, no access to other databases).

### Useful variations

**Restrict to a single table:**

```sql
GRANT INSERT ON my_database.my_table TO insert_user;
```

**Also allow CREATE TABLE:**

```sql
GRANT INSERT, CREATE TABLE ON my_database.* TO insert_user;
```

**Restrict by source IP (recommended if no password):**

```sql
CREATE USER insert_user NO PASSWORD HOST IP '10.0.0.0/8';
```

**Verify the grants:**

```sql
SHOW GRANTS FOR insert_user;
```

## Via XML Config

Users can also be defined in XML config files. Place a file in `/etc/clickhouse-server/users.d/` (drop-in directory). See `insert_user.xml` in this folder for a complete example.

### Key points

- Files in `users.d/` are merged automatically -- no restart needed, ClickHouse picks up changes on the fly.
- The `<grants>` section requires ClickHouse **22.4+**. On older versions, run the `GRANT` SQL statement separately after defining the user.
- XML-defined users cannot be modified via SQL (`ALTER USER` won't work on them). SQL-created users are stored separately in the `access/` directory on disk.
- Using the drop-in `users.d/` directory is preferred over editing `users.xml` directly, as it survives package upgrades cleanly.

## Security Note

`NO PASSWORD` means anyone who can reach the ClickHouse native port (9000) or HTTP port (8123) can authenticate as that user. At minimum, lock it down with `HOST IP` / `<networks>` or firewall rules.
