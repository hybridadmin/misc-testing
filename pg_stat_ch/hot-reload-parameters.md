# Hot-Reloading pg_stat_ch Parameters (e.g. batch_max)

## Check the Parameter Context First

Whether a parameter can be changed on the fly depends on its **context** in `pg_settings`:

```sql
SELECT name, setting, context
FROM pg_settings
WHERE name = 'pg_stat_ch.batch_max';
```

| Context      | Can hot-reload? | Method                          |
|-------------|----------------|---------------------------------|
| `user`       | Yes            | `SET` per session               |
| `superuser`  | Yes            | `SET` per session (superuser)   |
| `sighup`     | Yes            | `pg_reload_conf()` or `SIGHUP` |
| `postmaster` | **No**         | Full restart required           |

## Hot-Reload Methods

### If context is `sighup`

Change in `postgresql.conf` (or via `ALTER SYSTEM`), then reload:

```sql
ALTER SYSTEM SET pg_stat_ch.batch_max = 1000;
SELECT pg_reload_conf();
```

Or from the shell:

```bash
pg_ctl reload -D /path/to/data
# or
kill -HUP <postmaster_pid>
```

### If context is `user` or `superuser`

Can be set per-session without any reload:

```sql
SET pg_stat_ch.batch_max = 1000;
```

Or permanently (takes effect on new sessions after reload):

```sql
ALTER SYSTEM SET pg_stat_ch.batch_max = 1000;
SELECT pg_reload_conf();
```

### If context is `postmaster`

A full server **restart** is required -- hot-reload is not possible:

```sql
ALTER SYSTEM SET pg_stat_ch.batch_max = 1000;
-- Then restart PostgreSQL
```

## Notes

- If the extension does not register the parameter in `pg_settings`, check the extension's own documentation as it may use a custom configuration mechanism.
- `ALTER SYSTEM` writes to `postgresql.auto.conf`, which overrides values in `postgresql.conf`.
