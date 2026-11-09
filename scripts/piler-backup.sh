#!/bin/bash
#
# Backs up a piler installation of the Docker compose examples (v2) into
# a restic repository: a single node, or a node of a multi-node deployment.
# Run it in the directory of the installation (with docker-compose.yaml, or
# what COMPOSE_FILE names, and .env):
#
#   piler-backup.sh                       back up now (cron runs this)
#   piler-backup.sh install-cron [HH:MM]  back up every day (/etc/cron.d as
#                                         root; otherwise a crontab line)
#   piler-backup.sh snapshots             the backups in the repository
#   piler-backup.sh restore <id>          restore a backup into this, empty
#                                         installation (a new host)
#   piler-backup.sh extract <id> <dir>    extract the files of a backup
#
# What's in a backup: the databases (mariadb-dump), the search index
# (manticore-backup), the stored emails and attachments, /etc/piler, the
# error directory, and the installation: .env, the compose files and what the
# containers mount from this directory (env, piler.key, the license, ...).
# Other files of this directory are not in it.
# The settings are in .env:
#
#   BACKUP_REPOSITORY   the restic repository: s3:https://host/bucket/path,
#                       sftp:user@host:/path, rest:https://host/path, or a
#                       directory: an absolute path, outside this directory,
#                       on another disk (not a backup if the host is lost).
#                       A directory's repository isn't created by itself, a
#                       disk that isn't mounted would get a new one: for the
#                       first backup run BACKUP_INIT=1 piler-backup.sh
#   BACKUP_PASSWORD     encrypts the backup: without it there's no restore,
#                       keep a copy off this host
#   BACKUP_KEEP_DAILY, BACKUP_KEEP_WEEKLY, BACKUP_KEEP_MONTHLY
#                       how many backups are kept (7, 4, 12)
#   WORKDIR             the database dump and the installation files are
#                       put together here for the backup, in a directory of
#                       its own that's removed afterwards (backups/work).
#                       It needs room for the dump, which isn't encrypted
#                       there
#   BACKUP_MAINTENANCE  no: another node sharing the repository frees the space
#                       and checks it on Sundays (prune and check need it
#                       alone, one node is enough)
#   AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY   for an S3 repository
#   COMPOSE_FILE        the compose files, if not docker-compose.yaml
#                       (separated by ':'), as for docker compose itself
#
# Emails in S3 storage (multi-node workers) are not in it: back up the
# buckets with your object storage's tools (versioning, replication).

set -o nounset
set -o errexit
set -o pipefail

RESTIC_IMAGE="${BACKUP_RESTIC_IMAGE:-restic/restic:0.19.1}"
# What's in WORKDIR is copied here for restic: a volume, not a directory of
# the host (restic can't read the files of a macOS host through Docker Desktop)
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
   local compose_file="${COMPOSE_FILE:-}"
   local file

   [[ -f .env ]] || error "no .env here: run it in the directory of the installation"
   docker compose version >/dev/null 2>&1 || error "the docker compose plugin is not installed"

   # shellcheck disable=SC1091 # the settings of the installation
   . ./.env

   # The environment first, then .env, as docker compose does. Exported, so
   # every docker compose here uses the files that are backed up
   export COMPOSE_FILE="${compose_file:-${COMPOSE_FILE:-docker-compose.yaml}}"
   IFS="${COMPOSE_PATH_SEPARATOR:-:}" read -r -a COMPOSE_FILES <<< "$COMPOSE_FILE"
   for file in "${COMPOSE_FILES[@]}"; do
      [[ -f "$file" ]] || error "no ${file} here: run it in the directory of the installation, or set COMPOSE_FILE"
   done

   [[ -n "${BACKUP_REPOSITORY:-}" ]] || error "BACKUP_REPOSITORY is not set in .env, see the top of $0"
   [[ -n "${BACKUP_PASSWORD:-}" ]] || error "BACKUP_PASSWORD is not set in .env, e.g. echo \"BACKUP_PASSWORD=\$(openssl rand -hex 32)\" >> .env, and keep a copy off this host"

   case "$BACKUP_REPOSITORY" in
      /*|s3:*|sftp:*|rest:*) ;;
      *) error "BACKUP_REPOSITORY must be s3:..., sftp:..., rest:... or an absolute path: $BACKUP_REPOSITORY" ;;
   esac

   # The name of this node in the repository: snapshots are kept per node
   NODE="${WORKER_NAME:-${PILER_HOSTNAME:-$(hostname)}}"
}

# This directory goes into every backup: a repository in it would be backed
# up into itself, and grow with every backup
check_outside_installation() {
   local dir="${BACKUP_REPOSITORY%/}"
   local rest=""

   [[ "$BACKUP_REPOSITORY" == /* ]] || return 0

   # The path may not exist yet, resolve what does
   while [[ ! -d "$dir" ]]; do
      rest="/$(basename "$dir")${rest}"
      dir="$(dirname "$dir")"
   done

   case "$(cd "$dir" && pwd -P)${rest}/" in
      "$(pwd -P)"/*) error "the repository ${BACKUP_REPOSITORY} is in the directory of the installation, which is backed up: move it out" ;;
   esac
}

# 0: it's there, 1: there's none, else: it can't be read (network, the
# password, the S3 keys), which is recorded and stops the backup
repository_state() {
   local out
   local rc

   if [[ "$BACKUP_REPOSITORY" == /* && ! -d "$BACKUP_REPOSITORY" ]]; then
      return 1
   fi
   # Exit code 10 (restic 0.17+): no repository. The text isn't enough, a
   # failed pull of the image says "repository does not exist" too.
   if out="$(restic -- cat config 2>&1 >/dev/null)"; then
      return 0
   else
      rc=$?
   fi
   [[ "$rc" == 10 ]] && return 1
   echo "$out" | tail -3 >&2
   return 2
}

repository_exists() {
   repository_state 2>/dev/null
}

# A directory only with BACKUP_INIT=1: without its disk, the path is on the
# disk of this host, and the backups would go there unnoticed
create_repository() {
   if [[ "$BACKUP_REPOSITORY" == /* ]]; then
      if [[ -z "${BACKUP_INIT:-}" ]]; then
         record email_store failed 0
         error "no repository in ${BACKUP_REPOSITORY}. Is its disk mounted? A new repository: BACKUP_INIT=1 $0"
      fi
      if [[ -n "$(ls -A "$BACKUP_REPOSITORY" 2>/dev/null)" ]]; then
         error "${BACKUP_REPOSITORY} has files, but no repository: use an empty directory"
      fi
      mkdir -p "$BACKUP_REPOSITORY"
   fi

   log "Creating the repository"
   if ! restic -- init >/dev/null; then
      record email_store failed 0
      error "couldn't create the repository ${BACKUP_REPOSITORY}"
   fi
}

# restic in a container: restic [docker run options --] restic arguments
restic() {
   local opts=()
   local repo_mount=()

   while [[ $# -gt 0 && "$1" != "--" ]]; do opts+=("$1"); shift; done
   [[ "${1:-}" == "--" ]] && shift

   # A local repository is mounted at the same path
   if [[ "$BACKUP_REPOSITORY" == /* ]]; then
      # Docker would create it
      [[ -d "$BACKUP_REPOSITORY" ]] || error "no repository in ${BACKUP_REPOSITORY}. Is its disk mounted?"
      repo_mount=(-v "${BACKUP_REPOSITORY}:${BACKUP_REPOSITORY}")
   elif [[ "$BACKUP_REPOSITORY" == sftp:* ]]; then
      repo_mount=(-v "${HOME:-/root}/.ssh:/root/.ssh:ro")
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
   if [[ -n "${WORK:-}" ]]; then
      rm -rf "$WORK"
   fi
   if [[ -n "${ERRORS:-}" ]]; then
      rm -f "$ERRORS"
   fi
   if [[ -n "${MANTICORE_ID:-}" ]]; then
      docker exec "$MANTICORE_ID" rm -rf "$MANTICORE_STAGING" 2>/dev/null || true
   fi
   rm -rf "$LOCK"
}

# The directory of this backup in WORKDIR, the only one that's removed:
# WORKDIR itself may be any directory. It's named after the node, so a backup
# that didn't finish doesn't leave its dump behind.
prepare_workdir() {
   WORKDIR="${WORKDIR:-$PWD/backups/work}"

   [[ "$WORKDIR" == /* && "$WORKDIR" != "/" ]] || error "WORKDIR must be an absolute path: $WORKDIR"
   case "${WORKDIR%/}/" in
      "${BACKUP_REPOSITORY%/}"/*) error "WORKDIR can't be in the repository: $WORKDIR" ;;
   esac
   # The work directory is removed: it mustn't hold the repository
   case "${BACKUP_REPOSITORY%/}/" in
      "${WORKDIR%/}"/*) error "the repository can't be in WORKDIR: $BACKUP_REPOSITORY" ;;
   esac

   mkdir -p "$WORKDIR"
   # In a directory others can write, they could swap the work directory for a
   # link, and the dump would go where it points
   [[ ! -L "$WORKDIR" && "$(stat -c %u "$WORKDIR" 2>/dev/null || stat -f %u "$WORKDIR")" == "$(id -u)" \
      && "$(( 0$(stat -c %a "$WORKDIR" 2>/dev/null || stat -f %Lp "$WORKDIR") & 022 ))" == 0 ]] \
      || error "WORKDIR ${WORKDIR} must be yours, and not writable by others (chmod go-w)"
   rm -rf "${WORKDIR%/}/piler-backup-${NODE}"
   mkdir -m 700 "${WORKDIR%/}/piler-backup-${NODE}"
   WORK="${WORKDIR%/}/piler-backup-${NODE}"
   mkdir "$WORK/database" "$WORK/installation"
}

# The files of the installation: what the containers mount from its
# directory, and the compose files. Asking the containers, as a list of files
# would miss a custom one, and a copy of the directory would bring anything
# that's there.
collect_installation() {
   local project_dir
   local id

   project_dir="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$PILER_ID")"
   [[ -n "$project_dir" ]] || project_dir="$PWD"

   # Every failure is returned by hand: errexit is off in the "if !" of the
   # caller, and a file left out would only show at a restore
   {
      for id in $(docker compose ps -aq); do
         docker inspect -f '{{range .Mounts}}{{if eq .Type "bind"}}{{println .Source}}{{end}}{{end}}' "$id" || exit 1
      done
      docker inspect -f '{{index .Config.Labels "com.docker.compose.project.config_files"}}' "$PILER_ID" | tr ',' '\n' || exit 1
   } | sed 's#^/host_mnt/#/#' | sort -u | while IFS= read -r path; do  # /host_mnt: Docker Desktop
      case "$path" in
         "$project_dir"/*) (cd "$project_dir" && find "./${path#"$project_dir"/}" -type f -o -type l) || exit 1 ;;
      esac
   done | COPYFILE_DISABLE=1 tar -C "$project_dir" -chf - -T - | tar -xf - -C "$WORK/installation" || return 1

   # -h: the file behind a symbolic link
   COPYFILE_DISABLE=1 tar -C "$PWD" -chf - .env "${COMPOSE_FILES[@]}" | tar -xf - -C "$WORK/installation" || return 1

   # A backup without the key would look fine, but can't be read
   [[ -f "$WORK/installation/piler.key" ]]
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
   local errors
   local rc

   load_settings
   check_outside_installation
   take_lock
   trap cleanup EXIT

   MYSQL_ID="$(docker compose ps -q --status running mysql)"
   PILER_ID="$(docker compose ps -q --status running piler)"
   MANTICORE_ID="$(docker compose ps -q --status running manticore)"
   [[ -n "$MYSQL_ID" ]] || error "MariaDB isn't running in the compose project ${COMPOSE_PROJECT_NAME:-$(basename "$PWD")}. Started from a directory of another name? Set COMPOSE_PROJECT_NAME in .env"
   # Without piler there are no volumes to back up: stop, and record it
   if [[ -z "$PILER_ID" ]]; then
      record email_store failed 0
      error "piler isn't running"
   fi
   # Without Manticore the rest is still backed up: the index can be rebuilt
   # (reindex), the failure is recorded at the end
   if [[ -z "$MANTICORE_ID" ]]; then
      manticore_ok=0
      log "WARNING: Manticore isn't running: backing up without the search index, a restore needs a reindex"
   fi

   log "Backing up ${NODE} into ${BACKUP_REPOSITORY}"

   local state=0
   repository_state || state=$?
   case "$state" in
      0) ;;
      1) create_repository ;;
      *) record email_store failed 0; error "can't read the repository ${BACKUP_REPOSITORY} (see above)" ;;
   esac

   prepare_workdir

   # 1. The databases, first: the emails archived during the backup are in
   #    the store then, a restore doesn't miss their files
   log "Dumping the databases"
   if ! docker compose exec -T -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql \
        mariadb-dump -uroot --all-databases --single-transaction --routines --events --flush-privileges \
        > "$WORK/database/mariadb-all-databases.sql"; then
      record database failed 0
      error "the database dump failed"
   fi
   db_size="$(wc -c < "$WORK/database/mariadb-all-databases.sql" | tr -d ' ')"
   if [[ "$db_size" -lt 1000 ]]; then
      record database failed "$db_size"
      error "the database dump is empty"
   fi

   # 2. The search index, consistent while Manticore runs
   if [[ "$manticore_ok" == 1 ]]; then
      log "Backing up the search index"
      if docker exec -e TELEMETRY=0 "$MANTICORE_ID" sh -c "rm -rf $MANTICORE_STAGING && mkdir -p $MANTICORE_STAGING && manticore-backup --config=/etc/manticoresearch/manticore.conf.sh --backup-dir=$MANTICORE_STAGING" \
           > "$WORK/database/manticore-backup.log" 2>&1; then
         manticore_size="$(docker exec "$MANTICORE_ID" du -sb "$MANTICORE_STAGING" | cut -f1)"
      else
         manticore_ok=0
         log "WARNING: the search index wasn't backed up (see manticore-backup.log in the backup): a restore needs a reindex"
      fi
   fi

   # 3. Everything into one snapshot
   log "Collecting the files of the installation"
   if ! collect_installation; then
      record email_store failed 0
      error "couldn't read the files of the installation (not run as root?), or piler.key isn't among them"
   fi
   stage 'rm -rf /staging/* && chmod 700 /staging'
   COPYFILE_DISABLE=1 tar -C "$WORK" -cf - . | stage 'tar -xf - -C /staging' \
      || error "couldn't copy ${WORK} for the backup"
   paths="$(docker run --rm --volumes-from "${PILER_ID}:ro" --entrypoint sh "$RESTIC_IMAGE" -c \
      "for p in $PILER_PATHS; do if [ -d \"\$p\" ]; then printf '%s ' \"\$p\"; fi; done")"
   [[ "$manticore_ok" == 1 ]] && paths+=" $MANTICORE_STAGING"

   log "Writing the snapshot"
   # /staging: the dump and the installation. The license and the key
   # mounted into the piler container are among the files of the installation.
   # The errors are on stderr
   ERRORS="$(mktemp)"
   # shellcheck disable=SC2086 # paths is a list
   if out="$(restic --volumes-from "${PILER_ID}:ro" ${MANTICORE_ID:+--volumes-from "${MANTICORE_ID}:ro"} \
        -v "${STAGING_VOLUME}:/staging:ro" -- \
        backup --retry-lock 1h --json --quiet --host "$NODE" --tag piler \
        --exclude /etc/piler/license.jwt --exclude /etc/piler/piler.key \
        /staging $paths 2> "$ERRORS")"; then
      rc=0
   else
      rc=$?
   fi

   summary="$(grep '"message_type":"summary"' <<< "$out" || true)"
   snapshot="$(sed -n 's/.*"snapshot_id":"\([0-9a-f]*\)".*/\1/p' <<< "$summary")"
   total="$(sed -n 's/.*"total_bytes_processed":\([0-9]*\).*/\1/p' <<< "$summary")"

   # Exit code 3: files that couldn't be read. Those gone since restic listed
   # them (an uploaded S3 file, a purged email) are fine, anything else makes
   # the snapshot incomplete
   errors="$(grep '"message_type":"error"' "$ERRORS" || true)"
   if [[ "$rc" == 3 && -n "$snapshot" && -n "$errors" ]] \
      && ! grep -q -v 'no such file or directory' <<< "$errors"; then
      log "WARNING: $(wc -l <<< "$errors" | tr -d ' ') files were removed during the backup"
      rc=0
   fi

   if [[ "$rc" != 0 || -z "$snapshot" ]]; then
      tail -5 "$ERRORS" >&2
      [[ -n "$snapshot" ]] && restic -- forget --retry-lock 1h --quiet "$snapshot" >/dev/null 2>&1
      record email_store failed 0
      error "the snapshot failed (restic exit code ${rc})"
   fi
   log "Snapshot ${snapshot:0:8}: $(( ${total:-0} / 1048576 )) MB, of them new: $(( $(sed -n 's/.*"data_added":\([0-9]*\).*/\1/p' <<< "$summary") / 1048576 )) MB"

   # 4. Old snapshots go; on Sundays the space is freed and a sample of the
   #    data is read back
   log "Removing the old snapshots"
   # Grouped by node: a node whose paths change (a new volume) keeps no old snapshots
   # --retry-lock: the nodes may share the repository, wait for another one's prune
   restic -- forget --retry-lock 1h --quiet --host "$NODE" --tag piler --group-by host,tags \
      --keep-daily "${BACKUP_KEEP_DAILY:-7}" --keep-weekly "${BACKUP_KEEP_WEEKLY:-4}" \
      --keep-monthly "${BACKUP_KEEP_MONTHLY:-12}" >/dev/null || log "WARNING: removing the old snapshots failed"

   # BACKUP_MAINTENANCE=no: another node sharing the repository does it
   if [[ "${BACKUP_MAINTENANCE:-yes}" != no && ( "$(date +%u)" == 7 || -n "${BACKUP_CHECK_NOW:-}" ) ]]; then
      log "Freeing the space of the removed snapshots, checking 5% of the data"
      restic -- prune --retry-lock 1h --quiet >/dev/null || log "WARNING: prune failed"
      if restic -- check --retry-lock 1h --read-data-subset=5% >/dev/null 2>&1; then
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

# A file in /etc/cron.d as root, otherwise the line for a crontab. The lock
# of the backup keeps a run from starting while another one is running.
install_cron() {
   local at="${1:-02:30}"
   local script
   local file
   local line

   load_settings
   [[ "$at" =~ ^[0-2][0-9]:[0-5][0-9]$ ]] || error "not a time: $at (HH:MM)"
   check_outside_installation
   if [[ "$BACKUP_REPOSITORY" == /* ]] && ! repository_exists; then
      echo "WARNING: no repository in ${BACKUP_REPOSITORY} yet, the backups will fail. Create it: BACKUP_INIT=1 $0"
   fi
   script="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
   mkdir -p backups
   chmod 700 backups
   line="${at#*:} ${at%:*} * * *"

   if [[ "$(id -u)" != 0 || ! -d /etc/cron.d ]]; then
      cat << EOF
Not root, or no /etc/cron.d here. Add this line to root's crontab (crontab -e):

${line} cd "${PWD}" && "${script}" >> "${PWD}/backups/backup.log" 2>&1
EOF
      return
   fi

   # Nothing would run the file
   if ! pgrep -x cron >/dev/null && ! pgrep -x crond >/dev/null; then
      error "no cron daemon runs here: install and start cron (or cronie), or run the backup with another scheduler"
   fi

   # The timer of an earlier version, for this installation, would run it twice
   if [[ -f /etc/systemd/system/piler-backup.service ]]; then
      if grep -qxF "WorkingDirectory=${PWD}" /etc/systemd/system/piler-backup.service; then
         systemctl disable --now piler-backup.timer >/dev/null 2>&1 || true
         rm -f /etc/systemd/system/piler-backup.timer /etc/systemd/system/piler-backup.service
         systemctl daemon-reload >/dev/null 2>&1 || true
         echo "Removed the systemd timer of an earlier version"
      else
         echo "WARNING: /etc/systemd/system/piler-backup.timer backs up another installation, left as it is"
      fi
   fi

   # cron ignores a file whose name has a dot
   file="/etc/cron.d/piler-backup-$(printf '%s' "$NODE" | tr -c 'A-Za-z0-9_-' '_')"
   cat > "$file" << EOF
# The piler backup of ${PWD}, by piler-backup.sh install-cron
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin
${line} root cd "${PWD}" && "${script}" >> "${PWD}/backups/backup.log" 2>&1
EOF
   chmod 644 "$file"

   echo "The backup runs every day at ${at}: ${file}"
   echo "Its log: ${PWD}/backups/backup.log"
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
        v && /external: true/ { print name }' "${COMPOSE_FILES[@]}"
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
   install-cron) install_cron "${2:-}" ;;
   # The name of an earlier version
   install-timer) install_cron "${2:-}" ;;
   snapshots) snapshots ;;
   restore) restore "${2:-}" ;;
   extract) extract "${2:-}" "${3:-}" ;;
   -h|--help|*) usage ;;
esac
