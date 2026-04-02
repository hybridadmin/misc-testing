# PostgreSQL `permission denied for schema public`

## Error

```
sqlalchemy.exc.ProgrammingError: (sqlalchemy.dialects.postgresql.asyncpg.ProgrammingError)
<class 'asyncpg.exceptions.InsufficientPrivilegeError'>: permission denied for schema public
[SQL:
CREATE TABLE alembic_version (
    version_num VARCHAR(32) NOT NULL,
    CONSTRAINT alembic_version_pkc PRIMARY KEY (version_num)
)
```

## Cause

The database user running Alembic migrations doesn't have the `CREATE` privilege on the `public` schema. This is very common with **PostgreSQL 15+**, which revoked the default `CREATE` on the `public` schema for all users except the database owner.

| PostgreSQL Version | Default behavior                                              |
| ------------------ | ------------------------------------------------------------- |
| **< 15**           | All users have `CREATE` on `public` schema by default         |
| **>= 15**          | Only the database owner has `CREATE` on `public` schema       |

## Fix

Connect to the database as a superuser or the database owner (e.g. `postgres`) and grant the necessary privileges:

```sql
-- Grant usage and create on the public schema to your app user
GRANT USAGE ON SCHEMA public TO <your_db_user>;
GRANT CREATE ON SCHEMA public TO <your_db_user>;

-- Also grant table-level privileges for ongoing operations
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO <your_db_user>;
```

Replace `<your_db_user>` with the actual database user the migration runs as.

## If Using AWS RDS / Aurora

The `postgres` master user is not a true superuser. You may need to:

```sql
-- Connect as the RDS master user, then:
GRANT ALL ON SCHEMA public TO <your_db_user>;

-- If the schema owner is 'rds_superuser' or 'postgres':
ALTER SCHEMA public OWNER TO <your_db_user>;
```

Changing the schema owner is the most reliable fix on RDS if you want that user to have full control.

## Verify Current Permissions

To check who owns the `public` schema and what grants exist:

```sql
-- Check schema owner
SELECT schema_name, schema_owner
FROM information_schema.schemata
WHERE schema_name = 'public';

-- Check current grants
SELECT grantee, privilege_type
FROM information_schema.role_usage_grants
WHERE object_schema = 'public';
```
