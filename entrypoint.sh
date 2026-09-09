#!/usr/bin/env bash
#
# GitBucket on Railway.
#
# Three jobs, in order:
#   1. size the JVM from the cgroup rather than the 48-core host,
#   2. point GitBucket at the managed PostgreSQL service,
#   3. replace the fixed root/root account GitBucket's own migration creates,
#      before anything is reachable from the internet.
#
set -euo pipefail

log() { echo "[entrypoint] $*"; }
die() { echo "[entrypoint] FATAL: $*" >&2; exit 1; }

BOOT_PORT="${GITBUCKET_BOOTSTRAP_PORT:-8099}"
DEFAULT_ROOT_SHA1="dc76e9f0c0006e8f919e0c515c66dbba3982f785" # sha1("root")

GITBUCKET_HOME="${GITBUCKET_HOME:-/gitbucket}"
export GITBUCKET_HOME
mkdir -p "$GITBUCKET_HOME"

# --------------------------------------------------------------- JVM sizing --
# Railway hosts report 48 cores and hundreds of GB while the container quota is a
# fraction of that. JDK 17 reads memory from the cgroup correctly but
# availableProcessors() still reads the host, so cap it explicitly.
cgroup_cpus() {
  local quota="max" period="100000" n
  if [ -r /sys/fs/cgroup/cpu.max ]; then
    read -r quota period < /sys/fs/cgroup/cpu.max || true
  fi
  if [ "$quota" != "max" ] && [ -n "$period" ] && [ "$period" -gt 0 ] 2>/dev/null; then
    n=$(( (quota + period - 1) / period ))
  else
    n=$(nproc)
  fi
  [ "$n" -ge 1 ] 2>/dev/null || n=1
  echo "$n"
}
CPUS="$(cgroup_cpus)"
# Operator-supplied JAVA_OPTS come last so they win.
JAVA_OPTS="-XX:MaxRAMPercentage=70 -XX:ActiveProcessorCount=${CPUS} -Djava.net.preferIPv6Addresses=true ${JAVA_OPTS:-}"
export JAVA_OPTS
log "cgroup cpus=${CPUS}; JAVA_OPTS=${JAVA_OPTS}"

# ----------------------------------------------------------------- database --
# GITBUCKET_DB_URL / _USER / _PASSWORD are read by GitBucket itself and override
# the database.conf it would otherwise write. An operator who sets them keeps them.
if [ -z "${GITBUCKET_DB_URL:-}" ]; then
  PGPORT="${PGPORT:-5432}"
  PGDATABASE="${PGDATABASE:-railway}"
  # RAILWAY_PRIVATE_DOMAIN renders empty on a service's first-ever deployment, so
  # ${{Postgres.PGHOST}} can arrive blank. The private hostname is deterministic.
  case "${PGHOST:-}" in "") PGHOST="postgres.railway.internal" ;; esac
  export PGHOST PGPORT PGDATABASE

  [ -n "${PGUSER:-}" ]     || die "PGUSER is not set. Reference \${{Postgres.PGUSER}}, or set GITBUCKET_DB_URL/_USER/_PASSWORD yourself."
  [ -n "${PGPASSWORD:-}" ] || die "PGPASSWORD is not set. Reference \${{Postgres.PGPASSWORD}}, or set GITBUCKET_DB_URL/_USER/_PASSWORD yourself."

  export GITBUCKET_DB_URL="jdbc:postgresql://${PGHOST}:${PGPORT}/${PGDATABASE}"
  export GITBUCKET_DB_USER="$PGUSER"
  export GITBUCKET_DB_PASSWORD="$PGPASSWORD"
  HAVE_PSQL=1
else
  HAVE_PSQL=0
  log "GITBUCKET_DB_URL supplied by the operator; skipping the managed-database wiring"
fi
log "database host=${PGHOST:-<from GITBUCKET_DB_URL>} db=${PGDATABASE:-<from GITBUCKET_DB_URL>}"

if [ "$HAVE_PSQL" = 1 ]; then
  ready=0
  for i in $(seq 1 60); do
    if pg_isready -q -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE"; then ready=1; break; fi
    log "waiting for postgres (${i}/60)"
    sleep 5
  done
  [ "$ready" = 1 ] || die "postgres at ${PGHOST}:${PGPORT} never became ready"
  log "postgres is ready"
fi

# ------------------------------------------------------------ base / ssh URL --
if [ -z "${GITBUCKET_BASE_URL:-}" ] && [ -n "${RAILWAY_PUBLIC_DOMAIN:-}" ]; then
  export GITBUCKET_BASE_URL="https://${RAILWAY_PUBLIC_DOMAIN}"
fi
[ -n "${GITBUCKET_BASE_URL:-}" ] && log "base url=${GITBUCKET_BASE_URL}"

# ------------------------------------------------------- administrator seed --
# GitBucket's Liquibase migration inserts a `root` account whose password is the
# sha1 of "root". Publishing that on the internet for even a few seconds is not
# acceptable, and there is no admin-password environment variable, so run the app
# on loopback once, let it build the schema, rewrite the row, and only then bind
# the public port. GitBucket accepts a bare sha1 as a legacy password and rewrites
# it as pbkdf2-sha256 on the first successful sign-in.
if [ "$HAVE_PSQL" = 1 ]; then
  MARKER="${GITBUCKET_HOME}/.railway-admin-$(printf '%s' "${PGHOST}/${PGDATABASE}" | sha1sum | cut -c1-16)"
  if [ ! -f "$MARKER" ]; then
    [ -n "${GITBUCKET_ADMIN_PASSWORD:-}" ] || \
      die "GITBUCKET_ADMIN_PASSWORD must be set on the first boot against a new database."

    log "first boot against this database: building the schema on 127.0.0.1:${BOOT_PORT}"
    (
      unset GITBUCKET_SSH GITBUCKET_SSH_HOST GITBUCKET_SSH_PORT \
            GITBUCKET_SSH_BINDADDRESS_HOST GITBUCKET_SSH_BINDADDRESS_PORT \
            GITBUCKET_SSH_PUBLICADDRESS_HOST GITBUCKET_SSH_PUBLICADDRESS_PORT
      exec java $JAVA_OPTS -jar /opt/gitbucket.war --host=127.0.0.1 --port="$BOOT_PORT"
    ) &
    BOOT_PID=$!

    ready=0
    for i in $(seq 1 180); do
      if curl -fsS -o /dev/null "http://127.0.0.1:${BOOT_PORT}/signin"; then ready=1; break; fi
      if ! kill -0 "$BOOT_PID" 2>/dev/null; then die "the bootstrap instance exited before it served a page"; fi
      sleep 2
    done
    if [ "$ready" != 1 ]; then
      kill "$BOOT_PID" 2>/dev/null || true
      die "the bootstrap instance never became ready"
    fi
    log "schema built; rewriting the built-in root password"

    # Liquibase leaves ACCOUNT unquoted, so PostgreSQL folds it to lower case — but
    # resolve the real identifiers rather than assuming a folding rule.
    ident() {
      psql -qtAX -v ON_ERROR_STOP=1 -c "$1" | head -1 | tr -d '[:space:]'
    }
    TBL="$(ident "SELECT quote_ident(table_schema) || '.' || quote_ident(table_name)
                    FROM information_schema.tables
                   WHERE lower(table_name) = 'account'
                     AND table_schema NOT IN ('pg_catalog', 'information_schema')
                   LIMIT 1;")"
    [ -n "$TBL" ] || die "GitBucket's ACCOUNT table is missing after the bootstrap boot"
    COL_USER="$(ident "SELECT quote_ident(column_name) FROM information_schema.columns
                        WHERE lower(table_name) = 'account' AND lower(column_name) = 'user_name' LIMIT 1;")"
    COL_PW="$(ident "SELECT quote_ident(column_name) FROM information_schema.columns
                      WHERE lower(table_name) = 'account' AND lower(column_name) = 'password' LIMIT 1;")"
    [ -n "$COL_USER" ] && [ -n "$COL_PW" ] || die "GitBucket's ACCOUNT table has no user_name/password column"
    log "account table resolved as ${TBL}"

    HASH="$(printf '%s' "$GITBUCKET_ADMIN_PASSWORD" | sha1sum | cut -d' ' -f1)"
    CHANGED="$(psql -qtAX -v ON_ERROR_STOP=1 -v h="$HASH" -v d="$DEFAULT_ROOT_SHA1" \
      -c "UPDATE ${TBL} SET ${COL_PW} = :'h' WHERE ${COL_USER} = 'root' AND ${COL_PW} = :'d' RETURNING ${COL_USER};" \
      | tr -d '[:space:]')"

    kill "$BOOT_PID" 2>/dev/null || true
    wait "$BOOT_PID" 2>/dev/null || true

    if [ "$CHANGED" = "root" ]; then
      log "root password set from GITBUCKET_ADMIN_PASSWORD"
    else
      log "root no longer carries the shipped default password; leaving it untouched"
    fi
    : > "$MARKER"
  else
    log "administrator already provisioned for this database; leaving the account alone"
  fi
fi

# -------------------------------------------------------------- ssh for git --
# One Railway TCP proxy fronts GitBucket's SSH daemon. Both halves are read from
# the environment on every boot, so a regenerated proxy port self-heals.
if [ -n "${RAILWAY_TCP_PROXY_DOMAIN:-}" ] && [ -n "${RAILWAY_TCP_PROXY_PORT:-}" ]; then
  export GITBUCKET_SSH="true"
  export GITBUCKET_SSH_BINDADDRESS_HOST="${RAILWAY_PRIVATE_DOMAIN:-127.0.0.1}"
  export GITBUCKET_SSH_BINDADDRESS_PORT="${RAILWAY_TCP_APPLICATION_PORT:-29418}"
  export GITBUCKET_SSH_PUBLICADDRESS_HOST="$RAILWAY_TCP_PROXY_DOMAIN"
  export GITBUCKET_SSH_PUBLICADDRESS_PORT="$RAILWAY_TCP_PROXY_PORT"
  log "ssh clone: git@${RAILWAY_TCP_PROXY_DOMAIN}:${RAILWAY_TCP_PROXY_PORT} (container port ${GITBUCKET_SSH_BINDADDRESS_PORT})"
else
  export GITBUCKET_SSH="false"
  log "ssh clone disabled: this service has no TCP proxy"
fi

log "starting GitBucket on 0.0.0.0:${PORT:-8080}"
exec java $JAVA_OPTS -jar /opt/gitbucket.war --host=0.0.0.0 --port="${PORT:-8080}"
