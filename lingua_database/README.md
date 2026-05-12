# lingua_database (PostgreSQL)

This container workspace contains the **Lingua** PostgreSQL schema and demo seed data.

## Files

- `init.sql` — idempotent schema + seed data for local/dev/demo.

## How to apply (manual)

If you have a Postgres DSN, you can apply the script with `psql`:

```bash
psql "postgresql://USER:PASSWORD@HOST:PORT/DB" -f init.sql
```

## How to apply (container init)

If you're using a standard `postgres` Docker image, copy/mount `init.sql` into:

- `/docker-entrypoint-initdb.d/init.sql`

Postgres will run it automatically on first initialization of the data directory.
