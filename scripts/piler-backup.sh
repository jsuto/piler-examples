#!/bin/bash
#
# Backs up a piler installation of the Docker compose examples (v2.2) into
# a restic repository: a single node, or a node of a multi-node deployment.
# Run it in the directory of the installation (with docker-compose.yaml and
# .env):
#
#   piler-backup.sh                       back up now (the timer runs this)
#   piler-backup.sh install-timer [HH:MM] back up every day (systemd timer,
#                                         as root; otherwise a cron line)
#   piler-backup.sh snapshots             the backups in the repository
#   piler-backup.sh restore <id>          restore a backup into this, empty
#                                         installation (a new host)
#   piler-backup.sh extract <id> <dir>    extract the files of a backup
#
# What's in a backup: the databases (mariadb-dump), the search index
# (manticore-backup), the stored emails and attachments, /etc/piler, the
# error directory, and this directory (.env, env, piler.key, the license).
# The settings are in .env:
#
#   BACKUP_REPOSITORY   the restic repository: s3:https://host/bucket/path,
#                       sftp:user@host:/path, rest:https://host/path, or a
#                       directory on this host (not a backup if the host is
#                       lost)
#   BACKUP_PASSWORD     encrypts the backup: without it there's no restore,
#                       keep a copy off this host
#   BACKUP_KEEP_DAILY, BACKUP_KEEP_WEEKLY, BACKUP_KEEP_MONTHLY
#                       how many backups are kept (7, 4, 12)
#   AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY   for an S3 repository
#
# Emails in S3 storage (multi-node workers) are not in it: back up the
# buckets with your object storage's tools (versioning, replication).

set -o nounset
set -o errexit
set -o pipefail

RESTIC_IMAGE="${BACKUP_RESTIC_IMAGE:-restic/restic:0.19.1}"
# The database dump and a copy of this directory are put together here: a
# volume, not a directory of the host (restic can't read the files of a
# macOS host through Docker Desktop)
STAGING_VOLUME="piler_backup_staging"
LOCK="backups/.lock"
# Inside the manticore container, on its data volume
MANTICORE_STAGING="/var/lib/manticore/piler-backup"
# The files of the piler container that are backed up, if the node has them
PILER_PATHS="/var/piler/store /var/piler/astore /etc/piler /var/piler/error /var/piler/tenant /var/piler/s3"

error() {
   echo "ERROR: $*" >&2
   exit 1
}

log() {
   echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

usage() {
   sed -n '3,16p' "$0" | sed 's/^# \{0,1\}//'
   exit 1
}

load_settings() {
   [[ -f .env && -f docker-compose.yaml ]] || error "no .env and docker-compose.yaml here: run it in the directory of the installation"
   docker compose version >/dev/null 2>&1 || error "the docker compose plugin is not installed"

   # shellcheck disable=SC1091 # the settings of the installation
   . ./.env

   [[ -n "${BACKUP_REPOSITORY:-}" ]] || error "BACKUP_REPOSITORY is not set in .env, see the top of $0"
   [[ -n "${BACKUP_PASSWORD:-}" ]] || error "BACKUP_PASSWORD is not set in .env, e.g. echo \"BACKUP_PASSWORD=\$(openssl rand -hex 32)\" >> .env, and keep a copy off this host"

   # The name of this node in the repository: snapshots are kept per node
   NODE="${WORKER_NAME:-${PILER_HOSTNAME:-$(hostname)}}"
}

# restic in a container: restic [docker run options --] restic arguments
restic() {
   local opts=()
   local repo_mount=()

   while [[ $# -gt 0 && "$1" != "--" ]]; do opts+=("$1"); shift; done
   [[ "${1:-}" == "--" ]] && shift

   # A local repository is mounted at the same path
   if [[ "$BACKUP_REPOSITORY" == /* ]]; then
      mkdir -p "$BACKUP_REPOSITORY"
      repo_mount=(-v "${BACKUP_REPOSITORY}:${BACKUP_REPOSITORY}")
   elif [[ "$BACKUP_REPOSITORY" == sftp:* ]]; then
      repo_mount=(-v "${HOME}/.ssh:/root/.ssh:ro")
   fi

   # ${a[@]+"${a[@]}"}: an empty array under nounset in bash 3 too
   docker run --rm ${opts[@]+"${opts[@]}"} ${repo_mount[@]+"${repo_mount[@]}"} \
      -e RESTIC_REPOSITORY="$BACKUP_REPOSITORY" \
      -e RESTIC_PASSWORD="$BACKUP_PASSWORD" \
      -e AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-}" \
      -e AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-}" \
      -e RESTIC_CACHE_DIR=/cache -v piler_restic_cache:/cache \
      "$RESTIC_IMAGE" "$@"
}

take_lock() {
   mkdir -p backups
   chmod 700 backups
   if ! mkdir "$LOCK" 2>/dev/null; then
      local pid
      pid="$(cat "$LOCK/pid" 2>/dev/null || true)"
      if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
         error "another backup is running (pid ${pid})"
      fi
      log "Removing the lock of a backup that didn't finish"
      rm -rf "$LOCK"
      mkdir "$LOCK"
   fi
   echo $$ > "$LOCK/pid"
}

# stage "commands": a shell in the staging volume (at /staging)
stage() {
   docker run -i --rm -v "${STAGING_VOLUME}:/staging" --entrypoint sh "$RESTIC_IMAGE" -c "$1"
}

cleanup() {
   stage 'rm -rf /staging/*' >/dev/null 2>&1 || true
   if [[ -n "${MANTICORE_ID:-}" ]]; then
      docker exec "$MANTICORE_ID" rm -rf "$MANTICORE_STAGING" 2>/dev/null || true
   fi
   rm -rf "$LOCK"
}

sql() {
   docker compose exec -T -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql mariadb -uroot -N piler -e "$1"
}

# record TYPE STATUS SIZE [VERIFIED]: a row for the health page, if the
# database has the backup_status table. TYPE: database, manticore,
# email_store; STATUS: success, failed; VERIFIED: pass, fail
record() {
   local verify_ts="NULL"
   local verify_status="NULL"

   if [[ "${HAS_STATUS_TABLE:-}" == "" ]]; then
      HAS_STATUS_TABLE="$(sql "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='piler' AND table_name='backup_status'" 2>/dev/null || echo 0)"
   fi
   [[ "$HAS_STATUS_TABLE" == 1 ]] || return 0

   if [[ -n "${4:-}" ]]; then
      verify_ts="$(date +%s)"
      verify_status="'$4'"
   fi

   sql "INSERT INTO backup_status (backup_type, backup_timestamp, backup_size_bytes, status, verification_timestamp, verification_status)
        VALUES ('$1', $(date +%s), $3, '$2', ${verify_ts}, ${verify_status})" >/dev/null 2>&1 \
      || log "WARNING: couldn't record the backup status in the database"
}

backup() {
   local db_size=0
   local manticore_size=0
   local manticore_ok=1
   local paths=""
   local summary
   local snapshot
   local total
   local verified=""
   local out
   local rc

   load_settings
   take_lock
   trap cleanup EXIT

   MYSQL_ID="$(docker compose ps -q --status running mysql)"
   PILER_ID="$(docker compose ps -q --status running piler)"
   MANTICORE_ID="$(docker compose ps -q --status running manticore)"
   [[ -n "$MYSQL_ID" && -n "$PILER_ID" ]] || error "MariaDB and piler must be running"

   log "Backing up ${NODE} into ${BACKUP_REPOSITORY}"

   # A new repository: create it
   if ! restic -- cat config >/dev/null 2>&1; then
      log "Creating the repository"
      restic -- init >/dev/null || error "couldn't create the repository ${BACKUP_REPOSITORY}"
   fi

   # 1. The databases, first: the emails archived during the backup are in
   #    the store then, a restore doesn't miss their files
   stage 'rm -rf /staging/database /staging/installation && mkdir -p /staging/database /staging/installation && chmod 700 /staging'
   log "Dumping the databases"
   if ! docker compose exec -T -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql \
        mariadb-dump -uroot --all-databases --single-transaction --routines --events --flush-privileges \
        | stage 'cat > /staging/database/mariadb-all-databases.sql'; then
      record database failed 0
      error "the database dump failed"
   fi
   db_size="$(stage 'wc -c < /staging/database/mariadb-all-databases.sql' | tr -d ' ')"
   if [[ "$db_size" -lt 1000 ]]; then
      record database failed "$db_size"
      error "the database dump is empty"
   fi

   # 2. The search index, consistent while Manticore runs
   if [[ -n "$MANTICORE_ID" ]]; then
      log "Backing up the search index"
      if docker exec -e TELEMETRY=0 "$MANTICORE_ID" sh -c "rm -rf $MANTICORE_STAGING && mkdir -p $MANTICORE_STAGING && manticore-backup --config=/etc/manticoresearch/manticore.conf.sh --backup-dir=$MANTICORE_STAGING" 2>&1 \
           | stage 'cat > /staging/database/manticore-backup.log'; then
         manticore_size="$(docker exec "$MANTICORE_ID" du -sb "$MANTICORE_STAGING" | cut -f1)"
      else
         manticore_ok=0
         log "WARNING: the search index wasn't backed up (see manticore-backup.log in the backup): a restore needs a reindex"
      fi
   else
      manticore_ok=0
      log "WARNING: Manticore isn't running, the search index isn't backed up"
   fi

   # 3. Everything into one snapshot
   COPYFILE_DISABLE=1 tar -C "$PWD" --exclude ./backups -cf - . | stage 'tar -xf - -C /staging/installation' \
      || error "couldn't copy this directory for the backup"
   paths="$(docker run --rm --volumes-from "${PILER_ID}:ro" --entrypoint sh "$RESTIC_IMAGE" -c \
      "for p in $PILER_PATHS; do if [ -d \"\$p\" ]; then printf '%s ' \"\$p\"; fi; done")"
   [[ "$manticore_ok" == 1 ]] && paths+=" $MANTICORE_STAGING"

   log "Writing the snapshot"
   # /staging: the dump and this directory (without the backups of
   # piler-upgrade.sh). The license and the key mounted into the piler
   # container are the files of this directory.
   # shellcheck disable=SC2086 # paths is a list
   if out="$(restic --volumes-from "${PILER_ID}:ro" ${MANTICORE_ID:+--volumes-from "${MANTICORE_ID}:ro"} \
        -v "${STAGING_VOLUME}:/staging:ro" -- \
        backup --json --quiet --host "$NODE" --tag piler \
        --exclude /etc/piler/license.jwt --exclude /etc/piler/piler.key \
        /staging $paths)"; then
      rc=0
   else
      rc=$?
   fi

   summary="$(grep '"message_type":"summary"' <<< "$out" || true)"
   snapshot="$(sed -n 's/.*"snapshot_id":"\([0-9a-f]*\)".*/\1/p' <<< "$summary")"
   total="$(sed -n 's/.*"total_bytes_processed":\([0-9]*\).*/\1/p' <<< "$summary")"

   # A file that couldn't be read leaves an incomplete snapshot (exit code 3)
   if [[ "$rc" != 0 || -z "$snapshot" ]]; then
      grep '"message_type":"error"\|"message_type":"exit_error"' <<< "$out" | head -5 >&2 || true
      [[ -n "$snapshot" ]] && restic -- forget --quiet "$snapshot" >/dev/null 2>&1
      record email_store failed 0
      error "the snapshot failed (restic exit code ${rc})"
   fi
   log "Snapshot ${snapshot:0:8}: $(( ${total:-0} / 1048576 )) MB, of them new: $(( $(sed -n 's/.*"data_added":\([0-9]*\).*/\1/p' <<< "$summary") / 1048576 )) MB"

   # 4. Old snapshots go; on Sundays the space is freed and a sample of the
   #    data is read back
   log "Removing the old snapshots"
   # Grouped by node: a node whose paths change (a new volume) keeps no old snapshots
   restic -- forget --quiet --host "$NODE" --tag piler --group-by host,tags \
      --keep-daily "${BACKUP_KEEP_DAILY:-7}" --keep-weekly "${BACKUP_KEEP_WEEKLY:-4}" \
      --keep-monthly "${BACKUP_KEEP_MONTHLY:-12}" >/dev/null || log "WARNING: removing the old snapshots failed"

   if [[ "$(date +%u)" == 7 || -n "${BACKUP_CHECK_NOW:-}" ]]; then
      log "Freeing the space of the removed snapshots, checking 5% of the data"
      restic -- prune --quiet >/dev/null || log "WARNING: prune failed"
      if restic -- check --read-data-subset=5% >/dev/null 2>&1; then
         verified="pass"
      else
         verified="fail"
         log "WARNING: the check of the repository failed: restic check"
      fi
   fi

   record database success "$db_size" "$verified"
   if [[ "$manticore_ok" == 1 ]]; then
      record manticore success "$manticore_size" "$verified"
   else
      record manticore failed 0
   fi
   record email_store success "${total:-0}" "$verified"

   log "Done"
}

install_timer() {
   local at="${1:-02:30}"
   local script

   load_settings
   [[ "$at" =~ ^[0-2][0-9]:[0-5][0-9]$ ]] || error "not a time: $at (HH:MM)"
   script="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

   if [[ "$(id -u)" != 0 || ! -d /run/systemd/system ]]; then
      cat << EOF
No systemd here, or not root. Add this line to root's crontab (crontab -e):

${at#*:} ${at%:*} * * * cd ${PWD} && ${script} >> ${PWD}/backups/backup.log 2>&1
EOF
      return
   fi

   cat > /etc/systemd/system/piler-backup.service << EOF
[Unit]
Description=piler backup (${PWD})
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
WorkingDirectory=${PWD}
ExecStart=${script}
EOF

   cat > /etc/systemd/system/piler-backup.timer << EOF
[Unit]
Description=Daily piler backup

[Timer]
OnCalendar=*-*-* ${at}:00
RandomizedDelaySec=10m
Persistent=true

[Install]
WantedBy=timers.target
EOF

   systemctl daemon-reload
   systemctl enable --now piler-backup.timer
   echo "The backup runs every day at ${at}: systemctl list-timers piler-backup.timer"
   echo "Its log: journalctl -u piler-backup.service"
   echo "Keep BACKUP_PASSWORD (in .env) off this host: without it there's no restore."
}

snapshots() {
   load_settings
   restic -- snapshots --tag piler
}

extract() {
   local id="${1:-}"
   local dir="${2:-}"

   [[ -n "$id" && -n "$dir" ]] || usage
   load_settings
   mkdir -p "$dir"
   dir="$(cd "$dir" && pwd)"
   restic -v "${dir}:/restore" -- restore "$id" --target /restore
   echo "Extracted into ${dir}"
}

# The volumes of the installation that docker compose doesn't create
external_volumes() {
   awk '/^volumes:/ { v = 1; next } /^[^ #]/ { v = 0 }
        v && /^  [a-z0-9_-]+:/ { name = $1; sub(":", "", name) }
        v && /external: true/ { print name }' docker-compose.yaml
}

restore() {
   local id="${1:-}"
   local backup_name
   local volume
   local piler_id
   local messages

   [[ -n "$id" ]] || usage
   load_settings

   if docker volume inspect piler_db >/dev/null 2>&1; then
      error "the piler_db volume exists: restore into an empty installation only. To replace this one: docker compose down, then remove its volumes (docker volume rm ...)"
   fi

   take_lock
   trap cleanup EXIT

   log "Restoring the files of this directory from ${id}"
   stage 'rm -rf /staging/* && chmod 700 /staging'
   restic -v "${STAGING_VOLUME}:/work" -- restore "$id" --target /work --include /staging/installation >/dev/null \
      || error "couldn't read ${id} from ${BACKUP_REPOSITORY}"
   stage 'tar -C /staging/staging/installation -cf - .' | tar -xf - -C "$PWD"
   chmod 600 .env
   # The settings of the backup: the versions, the passwords
   # shellcheck disable=SC1091
   . ./.env

   log "Creating the volumes"
   for volume in $(external_volumes); do
      docker volume create "$volume" >/dev/null
   done

   log "Restoring the databases"
   docker compose up -d --wait mysql >/dev/null 2>&1 || error "MariaDB didn't start"
   restic -- dump "$id" /staging/database/mariadb-all-databases.sql \
      | docker compose exec -T -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql mariadb -uroot \
      || error "the database restore failed"
   # The users and their rights came with the dump, MariaDB reads them now
   sql "FLUSH PRIVILEGES" >/dev/null || error "the database restore failed (FLUSH PRIVILEGES)"

   log "Restoring the emails and the files of piler"
   docker compose create >/dev/null 2>&1
   piler_id="$(docker compose ps -aq piler)"
   [[ -n "$piler_id" ]] || error "couldn't create the piler container"
   restic --volumes-from "$piler_id" -- restore "$id" --target / --include /var/piler --include /etc/piler >/dev/null \
      || error "the restore of the files failed"

   log "Restoring the search index"
   restic -v "${STAGING_VOLUME}:/work" -- restore "$id" --target /work --include "$MANTICORE_STAGING" >/dev/null 2>&1 || true
   backup_name="$(stage "ls /staging${MANTICORE_STAGING} 2>/dev/null | head -1" || true)"
   if [[ -n "$backup_name" ]]; then
      # What manticore-backup --restore does: its own restore insists on
      # writing the image's manticore.conf.sh, which exists. The tables, and
      # manticore.json (the list of the tables) into the data directory.
      docker compose run --rm --no-deps -v "${STAGING_VOLUME}:/work:ro" --entrypoint sh manticore -c \
         "set -e; b=/work${MANTICORE_STAGING}/${backup_name}; cp -a \$b/data/. /var/lib/manticore/; cp \$b/config/var/lib/manticore/manticore.json /var/lib/manticore/; if [ -n \"\$(ls -A \$b/state)\" ]; then cp -a \$b/state/. /var/lib/manticore/; fi; chown -R manticore:manticore /var/lib/manticore" >/dev/null \
         || error "the restore of the search index failed"
   else
      log "WARNING: the backup has no search index: reindex after the start"
   fi

   log "Starting piler"
   docker compose up -d --wait >/dev/null 2>&1 || error "not every service got healthy, see docker compose ps"

   messages="$(docker compose exec -T -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql mariadb -uroot -N piler -e 'SELECT COUNT(*) FROM metadata' 2>/dev/null || echo "?")"
   log "Done: ${messages} emails in the piler database. The emails archived after the backup are not in it."
}

case "${1:-backup}" in
   backup) backup ;;
   install-timer) install_timer "${2:-}" ;;
   snapshots) snapshots ;;
   restore) restore "${2:-}" ;;
   extract) extract "${2:-}" "${3:-}" ;;
   -h|--help|*) usage ;;
esac
