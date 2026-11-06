#!/bin/bash
#
# Sets up the single node piler: asks for the hostname, the license and the
# mail relay, then writes .env (docker compose) and env (piler, piler-ui,
# the scanner) with random passwords and keys, creates piler.key and the
# volumes. Run it once, in this directory, then: docker compose up -d --wait
#
# Without a terminal the answers come from the environment, e.g.
#   PILER_HOSTNAME=archive.example.com ACME_EMAIL=hostmaster@example.com \
#   LICENSE_FILE=/root/license.jwt SMARTHOST=mail.example.com ./setup.sh
#
# It never overwrites .env, env or piler.key: run it again after a failure,
# it continues with what's missing.

set -o nounset
set -o errexit
set -o pipefail

PILER_VERSION_DEFAULT="2.3.0"
PILER_SMTP_VERSION_DEFAULT="1.1.8"
SCANNER_VERSION_DEFAULT="1.3.2"

VOLUMES=( piler_db piler_manticore piler_etc piler_store piler_astore piler_tmp piler_traefik piler_error )

cd "$(dirname "$0")"

error() {
   echo "ERROR: $*" >&2
   exit 1
}

# 2n random hex characters
random_hex() {
   od -An -tx1 -N"$1" /dev/urandom | tr -d ' \n'
}

# ask VARIABLE "question" [default] [optional]: keeps a value from the
# environment. An optional answer may be empty.
ask() {
   local var="$1"
   local question="$2"
   local default="${3:-}"
   local optional="${4:-}"
   local answer

   if [[ -n "${!var+set}" && ( -n "${!var}" || -n "$optional" ) ]]; then
      return
   fi

   if [[ ! -t 0 ]]; then
      [[ -n "$default" || -n "$optional" ]] || error "$var is not set (no terminal to ask)"
      printf -v "$var" '%s' "$default"
      return
   fi

   if [[ -n "$default" ]]; then
      read -r -p "${question} [${default}]: " answer
      answer="${answer:-$default}"
   else
      read -r -p "${question}: " answer
   fi

   printf -v "$var" '%s' "$answer"
}

valid_hostname() {
   [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]]
}

check_requirements() {
   command -v docker >/dev/null || error "docker is not installed"
   docker compose version >/dev/null 2>&1 || error "the docker compose plugin is not installed"
   docker info >/dev/null 2>&1 || error "docker is not running, or $(id -un) may not use it"
   [[ -f env.dist && -f docker-compose.yaml ]] || error "run it in the single-node directory"
}

# Random passwords would lock piler out of an existing database
check_existing_installation() {
   if [[ ! -f .env ]] && docker volume inspect piler_db >/dev/null 2>&1; then
      error "the piler_db volume exists, this host has a piler already. Its passwords aren't these random ones: create .env by hand from the README (Existing installation)"
   fi
}

# The hostname in the license: piler-smtp accepts emails to addresses there only
license_hostname() {
   local payload

   payload="$(cut -d. -f2 license.jwt | tr '_-' '/+')"
   while (( ${#payload} % 4 )); do payload+="="; done
   base64 -d <<< "$payload" 2>/dev/null | grep -o '"hostname":"[^"]*"' | cut -d'"' -f4 || true
}

ask_settings() {
   local host
   local hosts
   local licensed

   licensed="$(license_hostname)"

   ask PILER_HOSTNAME "The hostname of the archive (DNS must point it to this host)" "$licensed"
   valid_hostname "$PILER_HOSTNAME" || error "not a hostname: $PILER_HOSTNAME"

   if [[ -n "$licensed" && "$(tr '[:upper:]' '[:lower:]' <<< "$PILER_HOSTNAME")" != "$(tr '[:upper:]' '[:lower:]' <<< "$licensed")" ]]; then
      echo "WARNING: the license is for ${licensed}: piler-smtp accepts the emails sent to addresses @${licensed} only"
   fi

   ask TENANT_HOSTNAMES "Hostnames of tenants, comma separated (multi-tenant license only, empty for none)" "" optional
   TENANT_HOSTNAMES="$(tr -d ' ' <<< "$TENANT_HOSTNAMES")"
   if [[ -n "$TENANT_HOSTNAMES" ]]; then
      IFS=',' read -r -a hosts <<< "$TENANT_HOSTNAMES"
      for host in "${hosts[@]}"; do
         valid_hostname "$host" || error "not a hostname: $host"
      done
   fi

   ask ACME_EMAIL "Email address for Let's Encrypt (certificate expiry notices)" "hostmaster@${PILER_HOSTNAME#*.}"
   [[ "$ACME_EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+$ ]] || error "not an email address: $ACME_EMAIL"

   ask BACKUP_REPOSITORY "Backup repository: s3:https://host/bucket/piler, sftp:user@host:/path, or a directory (empty: set it later in .env)" "" optional
   [[ -z "$BACKUP_REPOSITORY" || "$BACKUP_REPOSITORY" =~ ^(/|s3:|sftp:|rest:)[A-Za-z0-9:/@._%+=,~-]+$ ]] || error "not a restic repository: $BACKUP_REPOSITORY"
   [[ "$BACKUP_REPOSITORY" != "$PWD"/* ]] || error "the repository can't be in this directory, which is backed up: $BACKUP_REPOSITORY"
}

ask_smarthost() {
   ask SMARTHOST "Mail relay for the emails piler sends (restore, notifications)" "localhost"
   valid_hostname "$SMARTHOST" || [[ "$SMARTHOST" == localhost ]] || error "not a hostname: $SMARTHOST"
   ask SMARTHOST_PORT "Its port" "25"
   [[ "$SMARTHOST_PORT" =~ ^[0-9]+$ ]] || error "not a port: $SMARTHOST_PORT"
}

write_compose_env() {
   if [[ -f .env ]]; then
      echo "Keeping .env"
      # PILER_HOSTNAME and MYSQL_PASSWORD for env
      # shellcheck disable=SC1091 # written by this script
      . ./.env
      return
   fi

   MYSQL_PASSWORD="$(random_hex 16)"

   (
      umask 077
      cat > .env << EOF
# Settings of this installation, read by docker compose. Written by setup.sh.

# The archive's address, and the tenants' (comma separated): traefik gets a
# certificate of each. PILER_HOSTNAME is written into the database at the
# first start, changing it here later doesn't change it there.
PILER_HOSTNAME=${PILER_HOSTNAME}
TENANT_HOSTNAMES=${TENANT_HOSTNAMES}
ACME_EMAIL=${ACME_EMAIL}

# Used when the database is created only: changing them here doesn't change
# the database. MYSQL_PASSWORD is in env too.
MYSQL_PASSWORD=${MYSQL_PASSWORD}
MYSQL_ROOT_PASSWORD=$(random_hex 16)

PILER_VERSION=${PILER_VERSION_DEFAULT}
PILER_SMTP_VERSION=${PILER_SMTP_VERSION_DEFAULT}
SCANNER_VERSION=${SCANNER_VERSION_DEFAULT}

# Backups, by scripts/piler-backup.sh of piler-examples (restic). The
# repository: s3:https://host/bucket/path, sftp:user@host:/path,
# rest:https://host/path, or a directory on this host (not a backup if the
# host is lost). BACKUP_PASSWORD encrypts the backups: without it there's
# no restore, keep a copy off this host.
BACKUP_REPOSITORY=${BACKUP_REPOSITORY:-}
BACKUP_PASSWORD=$(random_hex 32)
BACKUP_KEEP_DAILY=7
BACKUP_KEEP_WEEKLY=4
BACKUP_KEEP_MONTHLY=12
# The dump is put together here for the backup (empty: backups/work)
WORKDIR=
# For an S3 repository
AWS_ACCESS_KEY_ID=
AWS_SECRET_ACCESS_KEY=
EOF
   )
   echo "Wrote .env"
}

write_piler_env() {
   if [[ -f env ]]; then
      echo "Keeping env"
      return
   fi

   # The values are hex or checked hostnames: nothing sed would read as special
   sed -e "s|@@MYSQL_PASSWORD@@|${MYSQL_PASSWORD}|" \
       -e "s|@@PILER_HOSTNAME@@|${PILER_HOSTNAME}|g" \
       -e "s|@@JWT_SECRET@@|$(random_hex 32)|" \
       -e "s|@@IMAP_ENCRYPT_KEY@@|$(random_hex 16)|" \
       -e "s|@@SMARTHOST@@|${SMARTHOST}|" \
       -e "s|@@SMARTHOST_PORT@@|${SMARTHOST_PORT}|" \
       env.dist > env.new

   local unknown
   unknown="$(grep -v '^#' env.new | grep '@@' | head -1 || true)"
   if [[ -n "$unknown" ]]; then
      rm -f env.new
      error "env.dist has a value setup.sh doesn't know: ${unknown}"
   fi

   # piler-ui and the scanner run as uid 2001, they must read it
   chmod 644 env.new
   mv env.new env
   echo "Wrote env"
}

create_key() {
   if [[ -f piler.key ]]; then
      echo "Keeping piler.key"
      return
   fi

   # The emails are encrypted with it: without it the archive can't be read
   dd if=/dev/urandom bs=64 count=1 of=piler.key 2>/dev/null
   chmod 644 piler.key
   echo "Wrote piler.key: keep a copy of it outside this host"
}

install_license() {
   if [[ ! -f license.jwt ]]; then
      ask LICENSE_FILE "Path of your license file (license.jwt)"
      [[ -f "$LICENSE_FILE" ]] || error "no such file: $LICENSE_FILE"
      cp "$LICENSE_FILE" license.jwt
      chmod 644 license.jwt
      echo "Copied the license"
   fi

   if [[ ! -f license.pub ]]; then
      curl -fsS -o license.pub https://download.mailpiler.com/license.pub \
         || error "couldn't download license.pub, get it from https://download.mailpiler.com/license.pub"
      echo "Downloaded license.pub"
   fi
}

create_volumes() {
   local volume

   for volume in "${VOLUMES[@]}"; do
      docker volume inspect "$volume" >/dev/null 2>&1 || docker volume create "$volume" >/dev/null
   done
   echo "Volumes ready"
}

check_dns() {
   if command -v getent >/dev/null && ! getent hosts "$PILER_HOSTNAME" >/dev/null; then
      echo "WARNING: ${PILER_HOSTNAME} doesn't resolve yet: Let's Encrypt can't issue its certificate until it points to this host"
   fi
}

main() {
   check_requirements
   check_existing_installation

   # First: the license has the hostname of the archive
   install_license

   if [[ ! -f .env ]]; then
      ask_settings
   fi

   write_compose_env

   if [[ ! -f env ]]; then
      ask_smarthost
   fi

   write_piler_env
   create_key
   create_volumes

   # Passwords and keys: not for the other users of this host. The
   # containers get the files through their mounts.
   chmod go-rwx .

   check_dns

   cat << EOF

Done. Start piler, it waits until every service is healthy:

   docker compose up -d --wait

Then open https://${PILER_HOSTNAME}/ and log in as admin@local with the
password pilerrocks, and change it.

Keep a copy of piler.key and .env off this host: without piler.key the
emails can't be read, without BACKUP_PASSWORD (in .env) the backups can't.

Daily backups: set BACKUP_REPOSITORY in .env (and the S3 keys), then as root

   ../../../scripts/piler-backup.sh install-cron

A directory as the repository: run BACKUP_INIT=1 ../../../scripts/piler-backup.sh
once first.
EOF
}

main "$@"
