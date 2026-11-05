#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

CONFIG="${CONFIG:-/etc/mysqlbackup.cnf}"
LOCK="${LOCK:-/run/lock/mysqlbackup.lock}"

if [ ! -r "$CONFIG" ]; then
  echo "ERROR: missing config file: $CONFIG" >&2
  exit 1
fi

# shellcheck disable=SC1090
. "$CONFIG"

# Defaults if not defined in /etc/mysqlbackup.cnf
DATE="${DATE:-$(date +%Y-%m-%d)}"
TIME_FORMAT="${TIME_FORMAT:-+%Y-%m-%d %H:%M:%S}"
PATERN="${PATERN:-/usr/local/sbin/mysql/mysqlbackup_patern}"
LOG="${LOG:-/var/log/mysqlbackup.log}"
ERROR_LOG="${ERROR_LOG:-/tmp/mysqlbackup.err}"
ERROR_LOG2="${ERROR_LOG2:-/tmp/mysqlbackup.filtered.err}"
CHECK_CREATED="${CHECK_CREATED:-1}"
CHECK_SIZE="${CHECK_SIZE:-1024}"
OPTIMIZE="${OPTIMIZE:-0}"
AGE="${AGE:-+30}"
HOST="${HOST:-$(hostname -f)}"
FROM="${FROM:-root@$(hostname -f)}"
EMAIL="${EMAIL:-root}"

: "${PREFIX:?ERROR: PREFIX is not set in $CONFIG}"

mkdir -p "$PREFIX"
mkdir -p "$(dirname "$LOG")"
mkdir -p "$(dirname "$ERROR_LOG")"
mkdir -p "$(dirname "$ERROR_LOG2")"
mkdir -p "$(dirname "$PATERN")"

if [ ! -f "$PATERN" ]; then
  cat > "$PATERN" <<'PATTERN'
Warning: Using a password on the command line interface can be insecure.
PATTERN
fi

touch "$LOG"
: > "$ERROR_LOG"
: > "$ERROR_LOG2"

exec >>"$LOG" 2>>"$ERROR_LOG"

echo
echo "===== $(date -Is) starting MySQL/MariaDB backup on ${HOST} ====="

exec 200>"$LOCK"
flock -n 200 || {
  echo "Another mysqlbackup instance is already running. Exiting."
  exit 0
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: required command not found: $1" >&2
    exit 1
  }
}

# Use the native MariaDB tool names where available; retain MySQL aliases.
if command -v mariadb >/dev/null 2>&1; then
  DB_CLIENT=mariadb
  if command -v mariadb-dump >/dev/null 2>&1; then
    DUMP_CLIENT=mariadb-dump
  else
    DUMP_CLIENT=mysqldump
  fi
  if command -v mariadb-check >/dev/null 2>&1; then
    CHECK_CLIENT=mariadb-check
  else
    CHECK_CLIENT=mysqlcheck
  fi
else
  DB_CLIENT=mysql
  DUMP_CLIENT=mysqldump
  CHECK_CLIENT=mysqlcheck
fi

need_cmd "$DB_CLIENT"
need_cmd "$DUMP_CLIENT"
if [ "$OPTIMIZE" = "1" ]; then
  need_cmd "$CHECK_CLIENT"
fi
need_cmd gzip
need_cmd find
need_cmd du
need_cmd grep

log_time() {
  date "$TIME_FORMAT"
}

backup_database() {
  local db="$1"
  local db_dir="$PREFIX/$db"
  local out_file="$db_dir/$DATE.sql.gz"
  local tmp_file="$out_file.tmp"
  local table_list checksize

  case "$db" in
    information_schema|performance_schema|mysql|sys)
      return 0
      ;;
    */*|*..*)
      echo "ERROR: refusing unsafe database name: $db" >&2
      return 1
      ;;
  esac

  mkdir -p "$db_dir"

  # Fail closed on inaccessible or empty schemas. This catches silently empty
  # dumps caused by an underprivileged backup account or wrong database.
  if ! table_list="$("$DB_CLIENT" -N -B --database="$db" -e 'SHOW FULL TABLES')"; then
    echo "ERROR: failed to list tables in database: $db" >&2
    return 1
  fi
  if [ -z "$table_list" ]; then
    echo "ERROR: no visible tables/views in database: $db (check database and backup privileges)" >&2
    return 1
  fi

  echo "$(log_time): starting $DUMP_CLIENT for $db"

  rm -f "$tmp_file"

  if ! "$DUMP_CLIENT" \
      --single-transaction \
      --quick \
      --routines \
      --events \
      --triggers \
      --hex-blob \
      --default-character-set=utf8mb4 \
      --max-allowed-packet=1073741824 \
      "$db" | gzip -c > "$tmp_file"; then
    rm -f "$tmp_file"
    echo "ERROR: database dump failed for database: $db" >&2
    return 1
  fi

  # Validate the temporary backup before replacing a previous good backup.
  if ! gzip -t "$tmp_file"; then
    rm -f "$tmp_file"
    echo "ERROR: invalid gzip backup for database: $db" >&2
    return 1
  fi

  checksize="$(du -sb "$tmp_file" | awk '{ print $1 }')"
  if [ "$CHECK_CREATED" = "1" ] && [ "$checksize" -lt "$CHECK_SIZE" ]; then
    rm -f "$tmp_file"
    echo "ERROR: backup is suspiciously small: $out_file size=$checksize" >&2
    return 1
  fi

  mv -f "$tmp_file" "$out_file"
  echo "$(log_time): finished database dump for $db > $out_file ($checksize bytes)"

  find "$db_dir" -type f -name '*.sql.gz' -mtime "$AGE" -delete
}

DATABASES="$("$DB_CLIENT" -N -B -e "SHOW DATABASES")"

if [ -z "$DATABASES" ]; then
  echo "ERROR: database client returned no databases" >&2
  exit 1
fi

backup_failed=0

while IFS= read -r db; do
  [ -n "$db" ] || continue

  if ! backup_database "$db"; then
    backup_failed=1
  fi
done <<< "$DATABASES"

if [ "$OPTIMIZE" = "1" ]; then
  echo "$(log_time): starting $CHECK_CLIENT analyze/optimize"
  if ! "$CHECK_CLIENT" -a -A; then
    echo "ERROR: database analyze failed" >&2
    backup_failed=1
  fi
  if ! "$CHECK_CLIENT" -o -A; then
    echo "ERROR: database optimize failed" >&2
    backup_failed=1
  fi
  echo "$(log_time): finished $CHECK_CLIENT analyze/optimize"
fi

# Filter known/accepted warnings.
grep -v -f "$PATERN" "$ERROR_LOG" > "$ERROR_LOG2" || true

if [ -s "$ERROR_LOG2" ]; then
  echo "$(log_time): errors detected during mysqlbackup"

  if command -v mail >/dev/null 2>&1; then
    mail -r "$FROM" -s "$HOST mysqlbackup" "$EMAIL" < "$ERROR_LOG2" || true
  else
    echo "WARN: mail command not found; cannot send mysqlbackup report" >&2
  fi
fi

if [ "$backup_failed" -ne 0 ]; then
  echo "ERROR: one or more database backups failed" >&2
  exit 1
fi

if [ -s "$ERROR_LOG2" ]; then
  echo "ERROR: mysqlbackup completed with warnings/errors. See $ERROR_LOG2" >&2
  exit 1
fi

rm -f "$ERROR_LOG" "$ERROR_LOG2"

echo "MySQL/MariaDB backup completed successfully"
echo "===== $(date -Is) finished MySQL/MariaDB backup ====="
