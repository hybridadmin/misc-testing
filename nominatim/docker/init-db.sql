-- Initialization script for external PostgreSQL.
-- Runs once when the postgres container is first created.
-- IMPORTANT: Do NOT create the 'nominatim' database here.
-- Nominatim's import command will create it itself.

-- Create the nominatim superuser role (needed for import)
-- The postgres user from POSTGRES_USER is already a superuser.

-- Create the www-data role used by Nominatim for web queries.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'www-data') THEN
    CREATE ROLE "www-data" LOGIN;
  END IF;
END
$$;
