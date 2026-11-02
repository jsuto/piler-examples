#!/bin/bash
#
# Upgrades a piler installation of the Docker compose examples (v2.2): a
# single node, or a node of a multi-node deployment. Run it in the
# directory of the installation (with docker-compose.yaml and .env):
#
#   piler-upgrade.sh                   the versions now, and the newer releases
#   piler-upgrade.sh 2.2.6             upgrade piler-ee (piler, piler-ui, ...)
#
# Options: --smtp <version> and --scanner <version> upgrade piler-smtp and
# the scanner too, --yes doesn't ask, --no-backup skips the database dump.
#
# Multi-node: upgrade the workers first, one at a time, then the master.
#
# It shows the upgrade notes of every release since yours and asks before
# doing anything; a release with an upgrade step needs your confirmation
# that it's done. Then it pulls the new images, dumps the database and
# copies .env and env into backups/, runs the migrations of the new version,
# sets the versions in .env, starts the new containers and waits until
# they're healthy. If they don't get healthy it says how to go back. It never
# downgrades.

set -o nounset
set -o errexit
set -o pipefail

NOTES_URL="${PILER_UPGRADE_NOTES_URL:-https://docs.mailpiler.com/piler-ee-fiber/upgrade-notes.txt}"
UPGRADE_DOCS="https://docs.mailpiler.com/piler-ee-fiber/upgrade/"

error() {
   echo "ERROR: $*" >&2
   exit 1
}

usage() {
   sed -n '3,14p' "$0" | sed 's/^# \{0,1\}//'
   exit 1
}

# version_gt a b: a is newer than b
version_gt() {
   [[ "$1" != "$2" && "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" == "$1" ]]
}

valid_version() {
   [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]
}

confirm() {
   local answer

   [[ "$YES" == 1 ]] && return 0
   [[ -t 0 ]] || error "no terminal to ask: run it with --yes"
   read -r -p "$1 [y/N] " answer
   [[ "$answer" == y || "$answer" == Y ]]
}

# set_env KEY VALUE: in .env, keeping the file's permissions
set_env() {
   local tmp

   tmp="$(mktemp .env.XXXXXX)"
   if grep -q "^$1=" .env; then
      sed "s|^$1=.*|$1=$2|" .env > "$tmp"
   else
      cat .env > "$tmp"
      echo "$1=$2" >> "$tmp"
   fi
   chmod 600 "$tmp"
   mv "$tmp" .env
}

# The upgrade notes of the releases after $1 up to $2, the oldest first
notes_between() {
   awk -v from="$1" -v to="$2" '
      function newer(a, b,   i, x, y, n) {
         n = split(a, x, "."); split(b, y, ".")
         for (i = 1; i <= 4; i++) {
            if ((x[i] + 0) > (y[i] + 0)) return 1
            if ((x[i] + 0) < (y[i] + 0)) return 0
         }
         return 0
      }
      /^## / { keep = newer($2, from) && !newer($2, to); if (keep) { n++; block[n] = $0 }; next }
      /^#/ || /^$/ { next }
      keep { block[n] = block[n] "\n" $0 }
      END { for (i = n; i >= 1; i--) print block[i] "\n" }
   ' <<< "$NOTES"
}

run_sql() {
   docker compose exec -T -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql mariadb -uroot "$@"
}

# The piler database and those of the tenants, on this node
databases() {
   local all
   local tenant
   local tenants

   all=" $(run_sql -N -e 'SHOW DATABASES' | tr '\n' ' ')" || { echo "ERROR: couldn't list the databases" >&2; return 1; }
   [[ "$all" == *" piler "* ]] || { echo "ERROR: no piler database" >&2; return 1; }
   # Before migration 005 there's no tenant_settings, only piler
   tenants=""
   if [[ -n "$(run_sql -N -e "SHOW TABLES FROM piler LIKE 'tenant_settings'")" ]]; then
      tenants="$(run_sql -N -e "SELECT tenant_id FROM piler.tenant_settings WHERE tenant_id != 'piler'")" \
         || { echo "ERROR: couldn't read the tenants from piler.tenant_settings" >&2; return 1; }
   fi
   echo piler
   for tenant in $tenants; do
      if [[ "$all" == *" ${tenant} "* ]]; then echo "$tenant"; fi
   done
}

# All the migrations of the new version, on every database of the node: they
# are safe to run again (piler-ee checks it), so one skipped in an earlier
# upgrade is run too
run_migrations() {
   local new_image
   local dir
   local container
   local dbs
   local db

   # Every step returns by hand: errexit is off under the caller's "if"
   new_image="$(PILER_VERSION="$TARGET" docker compose config --images piler)" && [[ -n "$new_image" ]] \
      || { echo "ERROR: couldn't find the image of piler ${TARGET}" >&2; return 1; }
   dir="$(mktemp -d)" || return 1
   MIGRATIONS_DIR="$dir"
   container="$(docker create "$new_image")" || { echo "ERROR: couldn't create a container of ${new_image}" >&2; return 1; }
   docker cp -q "${container}:/usr/share/piler/migrations/." "$dir/" \
      || { docker rm -f "$container" >/dev/null; echo "ERROR: no migrations in ${new_image}" >&2; return 1; }
   docker rm -f "$container" >/dev/null

   ls "$dir"/sql/*.sql >/dev/null 2>&1 || { echo "ERROR: no SQL migrations in ${new_image}" >&2; return 1; }
   dbs="$(databases)" || return 1

   # All the files in one session per database: one exec each, not per file
   for db in $dbs; do
      echo "Migrations: ${db}"
      cat "$dir"/sql/*.sql | run_sql "$db" >/dev/null || { echo "ERROR: the migrations on ${db} (the line is of all the files)" >&2; return 1; }
   done

   # A master's tenant tables are distributed tables, the workers have the data
   if [[ "$ROLE" == "multi-node master" ]]; then
      return 0
   fi

   ls "$dir"/manticore/*.sql >/dev/null 2>&1 || return 0
   for db in $dbs; do
      sed "s/TENANTID/${db}/g" "$dir"/manticore/*.sql | docker compose exec -T manticore mysql -h0 -P9306 >/dev/null \
         || { echo "ERROR: the Manticore migrations on the index of ${db}" >&2; return 1; }
   done
}

# The services of piler-ee itself: they're stopped for the migrations, the old
# version mustn't work on a schema that changes under it. piler-smtp keeps
# taking the email, MariaDB and Manticore keep running.
app_services() {
   local service

   for service in $(docker compose config --services); do
      case "$service" in
         piler|piler-ui|scanner|s3uploader) echo "$service" ;;
      esac
   done
}

show_versions() {
   echo "piler-ee:   ${PILER_VERSION} (${ROLE})"
   [[ -z "${PILER_SMTP_VERSION:-}" ]] || echo "piler-smtp: ${PILER_SMTP_VERSION}"
   [[ -z "${SCANNER_VERSION:-}" ]] || echo "scanner:    ${SCANNER_VERSION}"
}

# ---------------------------------------------------------------------------

TARGET=""
SMTP_TARGET=""
SCANNER_TARGET=""
YES=0
BACKUP=1

while [[ $# -gt 0 ]]; do
   case "$1" in
      --smtp) SMTP_TARGET="${2:-}"; shift 2 ;;
      --scanner) SCANNER_TARGET="${2:-}"; shift 2 ;;
      --yes) YES=1; shift ;;
      --no-backup) BACKUP=0; shift ;;
      -h|--help) usage ;;
      -*) usage ;;
      *) [[ -z "$TARGET" ]] || usage; TARGET="$1"; shift ;;
   esac
done

[[ -f .env && -f docker-compose.yaml ]] || error "no .env and docker-compose.yaml here: run it in the directory of the installation"
docker compose version >/dev/null 2>&1 || error "the docker compose plugin is not installed"

# shellcheck disable=SC1091 # the settings of the installation
. ./.env
[[ -n "${PILER_VERSION:-}" ]] || error "PILER_VERSION is not in .env"

# Which node: the services tell (a profile in COMPOSE_PROFILES of .env counts)
SERVICES=" $(docker compose config --services 2>/dev/null | tr '\n' ' ')"
[[ "$SERVICES" == *" mysql "* ]] || error "docker compose can't read the configuration here, or it has no mysql service"
if [[ "$SERVICES" == *" s3uploader "* ]]; then
   ROLE="multi-node worker"
elif [[ "$SERVICES" != *" piler-smtp "* && -n "${WORKERS:-}" ]]; then
   ROLE="multi-node master"
else
   ROLE="single node"
fi

if NOTES="$(curl -fsS -m 30 "$NOTES_URL")"; then
   :
else
   NOTES=""
   echo "WARNING: couldn't download the upgrade notes (${NOTES_URL}), read them at ${UPGRADE_DOCS}"
fi

if [[ -z "$TARGET" ]]; then
   show_versions
   if [[ -n "$NOTES" ]]; then
      newer="$(grep '^## ' <<< "$NOTES" | awk '{print $2}' | while read -r v; do
         if version_gt "$v" "$PILER_VERSION"; then echo "$v"; fi
      done | sort -V | tr '\n' ' ')"
      echo
      echo "Newer piler-ee releases: ${newer:-none}"
   fi
   exit 0
fi

for v in "$TARGET" ${SMTP_TARGET:+"$SMTP_TARGET"} ${SCANNER_TARGET:+"$SCANNER_TARGET"}; do
   valid_version "$v" || error "not a version: $v"
done

version_gt "$PILER_VERSION" "$TARGET" && error "${TARGET} is older than ${PILER_VERSION}: downgrading isn't supported (the database may have changed), restore a backup instead"

if [[ "$TARGET" == "$PILER_VERSION" && -z "$SMTP_TARGET" && -z "$SCANNER_TARGET" ]]; then
   echo "piler-ee is ${PILER_VERSION} already"
   exit 0
fi

# --- The upgrade notes ------------------------------------------------------

STEPS=0
if [[ -n "$NOTES" && "$TARGET" != "$PILER_VERSION" ]]; then
   grep -q "^## ${TARGET//./\\.} " <<< "$NOTES" || {
      echo "WARNING: ${TARGET} isn't a released version in the upgrade notes"
      confirm "Upgrade to it anyway?" || exit 1
   }

   between="$(notes_between "$PILER_VERSION" "$TARGET")"
   echo "Upgrade notes of the releases after ${PILER_VERSION} (in full: ${UPGRADE_DOCS}):"
   echo
   if [[ -n "$(grep -v '^## \|^$' <<< "$between" || true)" ]]; then
      fold -s -w 78 <<< "$between"
   else
      echo "(none)"
      echo
   fi
   STEPS="$(grep -c '^Upgrade step:' <<< "$between" || true)"
fi

if [[ "$ROLE" == "multi-node master" && "$TARGET" != "$PILER_VERSION" ]]; then
   echo "This is the master: upgrade every worker to ${TARGET} first."
   confirm "Are the workers on ${TARGET}?" || exit 1
fi

if [[ "$STEPS" -gt 0 ]]; then
   echo "These releases have ${STEPS} upgrade step(s) above: do what they say for a Docker installation."
   confirm "Are the steps done, or done by the containers (read them)?" || exit 1
fi

echo "piler-ee ${PILER_VERSION} -> ${TARGET}${SMTP_TARGET:+, piler-smtp ${PILER_SMTP_VERSION:-?} -> ${SMTP_TARGET}}${SCANNER_TARGET:+, scanner ${SCANNER_VERSION:-?} -> ${SCANNER_TARGET}}"
confirm "Upgrade?" || exit 1

# --- The new images first: if they can't be pulled, nothing has changed -------

echo "Pulling the new images"
PILER_VERSION="$TARGET" \
PILER_SMTP_VERSION="${SMTP_TARGET:-${PILER_SMTP_VERSION:-}}" \
SCANNER_VERSION="${SCANNER_TARGET:-${SCANNER_VERSION:-}}" \
   docker compose pull --quiet || error "couldn't pull the images, nothing has changed"

# --- Backup -----------------------------------------------------------------

BACKUP_DIR="backups/$(date +%Y%m%d-%H%M%S)-${PILER_VERSION}-to-${TARGET}"
mkdir -p "$BACKUP_DIR"
chmod 700 backups "$BACKUP_DIR"
cp -p .env "$BACKUP_DIR/.env"
[[ -f env ]] && cp -p env "$BACKUP_DIR/env"

if [[ "$BACKUP" == 0 && "$TARGET" != "$PILER_VERSION" ]]; then
   echo "WARNING: --no-backup: if the migrations or the new version fail, there's no dump of the database to go back to"
fi

if [[ "$BACKUP" == 1 ]]; then
   [[ -n "$(docker compose ps -q --status running mysql)" ]] || error "MariaDB isn't running, start piler first (or --no-backup)"
   echo "Dumping the database into ${BACKUP_DIR}/db.sql.gz"
   # MYSQL_PWD: the password isn't on the command line in the container
   if ! docker compose exec -T -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql \
        mariadb-dump -uroot --all-databases --single-transaction --routines --events \
        | gzip > "$BACKUP_DIR/db.sql.gz"; then
      error "the database dump failed, nothing has changed"
   fi
   gzip -t "$BACKUP_DIR/db.sql.gz" && [[ "$(gzip -dc "$BACKUP_DIR/db.sql.gz" | head -c 1000 | wc -c)" -gt 100 ]] \
      || error "the database dump is empty, nothing has changed"
fi

# --- Migrations -------------------------------------------------------------

if [[ "$TARGET" != "$PILER_VERSION" ]]; then
   # Before the new containers (a new version may need them to start), with
   # the old ones stopped
   APP_SERVICES="$(app_services | tr '\n' ' ')"
   echo "Stopping ${APP_SERVICES}for the migrations (piler-smtp keeps taking the email)"
   # shellcheck disable=SC2086 # a list
   docker compose stop $APP_SERVICES >/dev/null 2>&1 || error "couldn't stop ${APP_SERVICES}"
   echo "Running the migrations"
   MIGRATIONS_DIR=""
   if ! run_migrations; then
      [[ -n "$MIGRATIONS_DIR" ]] && rm -rf "$MIGRATIONS_DIR"
      echo "ERROR: a migration failed, .env is unchanged. The database may be migrated in part." >&2
      if [[ "$BACKUP" == 1 ]]; then
         echo "Restore it before you start ${PILER_VERSION} again:" >&2
         echo "   gzip -dc ${BACKUP_DIR}/db.sql.gz | docker compose exec -T -e MYSQL_PWD=<MYSQL_ROOT_PASSWORD> mysql mariadb -uroot" >&2
         echo "   docker compose up -d --wait" >&2
      else
         echo "With --no-backup there's no dump to go back to: start ${PILER_VERSION} with docker compose up -d --wait, or fix the cause and run the upgrade again." >&2
      fi
      exit 1
   fi
   rm -rf "$MIGRATIONS_DIR"
fi

# --- Upgrade ----------------------------------------------------------------

OLD_PILER_VERSION="$PILER_VERSION"
set_env PILER_VERSION "$TARGET"
[[ -n "$SMTP_TARGET" ]] && set_env PILER_SMTP_VERSION "$SMTP_TARGET"
[[ -n "$SCANNER_TARGET" ]] && set_env SCANNER_VERSION "$SCANNER_TARGET"

echo "Starting the new containers, waiting until they're healthy"
if ! docker compose up -d --wait --wait-timeout 600; then
   echo
   docker compose ps
   cat >&2 << EOF

ERROR: not every service got healthy, see docker compose logs <service>.
If it doesn't recover, go back to ${OLD_PILER_VERSION}:

   cp ${BACKUP_DIR}/.env .env
EOF
   if [[ "$BACKUP" == 1 ]]; then
      cat >&2 << EOF
   gzip -dc ${BACKUP_DIR}/db.sql.gz | docker compose exec -T -e MYSQL_PWD=<MYSQL_ROOT_PASSWORD> mysql mariadb -uroot
EOF
   fi
   cat >&2 << EOF
   docker compose up -d --wait

The emails archived since the backup are in the store, but not in the
restored database: reindex them, see ${UPGRADE_DOCS}
EOF
   exit 1
fi

echo
echo "Done:"
# shellcheck disable=SC1091
. ./.env
show_versions
echo "Backup of the database and the settings: ${BACKUP_DIR}"
