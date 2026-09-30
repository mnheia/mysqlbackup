Copyright (c) 2026, Mnheia <mnheia@gmail.com>

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

The `mysql`, `mysqldump` and `mysqlcheck` clients automatically use that file.

## Configuration
Copy `mysqlbackup.cnf.example` to `/etc/mysqlbackup.cnf` and adjust the backup path, retention, notification address and optional maintenance settings.

The public configuration contains no database credentials.

## Backups
Each database is written as a compressed dump under the configured prefix:

```text
/var/backups/mysql/database_name/YYYYMMDD.sql.gz
```

System schemas such as `information_schema`, `performance_schema`, `mysql` and `sys` are skipped.

## Requirements
- Bash
- MySQL or MariaDB command-line client tools
- `gzip`
- `flock`
- standard GNU/Linux utilities
- optional `mail` command for error notifications

Run it as the user that owns the configured MySQL client credentials and backup destination. The default setup assumes root and `/root/.my.cnf`.

## Bugs
Please report bugs or feature requests through the web interface at https://github.com/mnheia/mysqlbackup/issues
