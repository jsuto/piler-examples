#!/bin/bash

set -o errexit
set -o pipefail
set -o nounset

SCRIPT_PATH="$(readlink -f "$0")"
SCRIPT_NAME="${SCRIPT_PATH##*/}"
SPHINX_DATA_DIR="/var/piler/sphinx"
PRIORITY="mail.info"
EXPORT_DIR="/var/piler/export"
CUSTOMERS=()
LICENSE_FILE="/etc/piler/piler.lic"
SERVERID="xx"
YESTERDAY="$(date -d yesterday +%Y.%m.%d)"
MIN_XZ_SIZE=100
ENCRYPTION_KEY="/etc/piler/backup.key"

## Be sure to fix this!!!
BUCKET_PREFIX="s3/your-bucket-prefix"


error() {
   echo "$*"
   exit 1
}

log() {
   logger -i -t "$SCRIPT_NAME" -p "$PRIORITY" <<< "$@"
}

get_server_id() {
   [[ -f "$LICENSE_FILE" ]] || error "No license file found"

   SERVERID=$(head -1 "$LICENSE_FILE" | sed 's/,/\n/g' | grep server_id | cut -f2 -d '=')
   SERVERID=$(printf "%02x" "$SERVERID")

   if [[ "$SERVERID" == "xx" ]]; then error "Invalid license file"; fi
}

get_customer_list() {
   local customer

   for customer in "$SPHINX_DATA_DIR"/*; do
      if [[ -d "$customer" ]]; then
         CUSTOMERS+=( "$(basename "$customer")" )
      fi
   done
}

backup_daily() {
   local customer="$1"
   local f
   local e
   local s3_bucket

   pushd "$EXPORT_DIR" >/dev/null

   s3_bucket="${BUCKET_PREFIX}-${customer}"

   log "s3 bucket: ${s3_bucket}"

   if mc stat "$s3_bucket" > /dev/null; then
      log "creating s3 bucket: ${s3_bucket}"
      mc -q mb "${s3_bucket}"
   fi

   f="${customer}-${YESTERDAY}.xz"
   e="${f}.enc"

   log "running export for ${customer}"

   pilerexport -W "$customer" -a "$YESTERDAY" -b "$YESTERDAY" -o | xz -c > "$f"

   log "checking size of ${f}"

   if [[ $(stat -c '%s' "$f") -gt $MIN_XZ_SIZE ]]; then
      log "encrypting ${f}"
      openssl enc -e -aes-256-ofb -in "$f" -out "$e" -pass "file:${ENCRYPTION_KEY}" -pbkdf2
      log "uploading ${e}"
      mc -q cp "$e" "$s3_bucket" || true
      log "uploaded ${e}"
   else
      log "skipping ${f}"
   fi

   rm -f "$f" "$e"

   popd >/dev/null

}

main() {
   local customer

   get_server_id
   get_customer_list

   for customer in "${CUSTOMERS[@]}"; do
      log "processing ${customer}"
      backup_daily "$customer"
   done
}

main "$@"
