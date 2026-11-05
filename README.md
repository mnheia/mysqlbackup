Copyright (c) 2026, mnheia

# mysqlbackup
Simple MySQL/MariaDB backup script with per-database compressed dumps, retention, size checks, locking, optional optimization and e-mail error reporting.

## Authentication
Database credentials are not stored in the script or the public configuration example.

Create `/root/.my.cnf` and restrict it to root:

```ini
[client]
user=backup
password=CHANGE_ME
host=localhost
```

```bash
chmod 600 /root/.my.cnf
```

The script automatically selects `mariadb`/`mariadb-dump`/`mariadb-check` when available, otherwise falling back to `mysql`/`mysqldump`/`mysqlcheck`. Both client families read defaults such as `/root/.my.cnf`.

## Configuration
Copy `mysqlbackup.cnf.example` to `/etc/mysqlbackup.cnf` and adjust the backup path, retention, notification address and optional maintenance settings.

The public configuration contains no database credentials.

`OPTIMIZE=0` is the default. Setting `OPTIMIZE=1` runs analyze and optimize against all databases. These operations can be expensive and may lock tables, so schedule them deliberately rather than as part of normal daily backups.

## Backups
Each database is written as a compressed dump under the configured prefix:

```text
/var/backups/mysql/database_name/YYYYMMDD.sql.gz
```

System schemas such as `information_schema`, `performance_schema`, `mysql` and `sys` are skipped.

Before replacing an existing same-day backup, the script checks that the schema contains at least one visible table or view, verifies the temporary gzip file with `gzip -t`, and (when `CHECK_CREATED=1`) enforces the configured `CHECK_SIZE` minimum. Invalid or undersized temporary dumps are removed; the previous backup is left untouched. Intentionally empty schemas are treated as failures to avoid silently creating unusable backups.

These checks are not a substitute for periodic test restores. The backup account must have enough privileges to see and dump **all** intended tables, views, triggers, routines and events. `--single-transaction` gives a consistent snapshot for transactional (e.g. InnoDB) tables; it does not guarantee consistency of non-transactional tables.

Newer MariaDB dumps may include a sandbox-mode header incompatible with older MariaDB or MySQL command-line restore clients. Use a compatible current MariaDB client for restores.

## Requirements
- Bash
- MySQL or MariaDB command-line client tools (prefer native MariaDB client names when installed)
- `gzip`
- `flock`
- standard GNU/Linux utilities
- optional `mail` command for error notifications

Run it as the user that owns the configured MySQL client credentials and backup destination. The default setup assumes root and `/root/.my.cnf`.

## Bugs
Please report bugs or feature requests through the web interface at https://github.com/mnheia/mysqlbackup/issues
