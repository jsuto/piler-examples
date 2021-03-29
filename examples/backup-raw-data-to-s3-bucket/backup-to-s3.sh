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

   STORE_DIR="/var/piler/store/${SERVERID}"
   ASTORE_DIR="/var/piler/astore/${SERVERID}"
}

get_customer_list() {
   local customer

   for customer in "$SPHINX_DATA_DIR"/*; do
      if [[ -d "$customer" ]]; then
         CUSTOMERS+=( "$(basename "$customer")" )
      fi
   done
}

backup_customer_dir() {
   local customer="$1"
   local basedir="$2"
   local prefix="$3"
   local level="$4"
   local dir
   local f
   local s3_uri

   pushd "${basedir}/${customer}" >/dev/null

   s3_uri="${BUCKET_PREFIX}-${customer}"

   if ! mc stat "$s3_uri" > /dev/null; then
      mc -q mb "$s3_uri"
   fi

   # We use "ls" because there are only alphanumeric directories to process
   # shellcheck disable=SC2012

   while read -r dir; do
      dir="${dir//\.\//}"
      f="${prefix}-${SERVERID}-${customer}-${dir}.tar"

      tar cf "$f" "$dir"
      mc -q cp "$f" "$s3_uri"
      rm -f "$f"
   done < <(ls -1t|head "-${level}")

   popd >/dev/null

}

backup_database() {
   local customer="$1"
   local f
   local s3_uri

   f="${EXPORT_DIR}/db-${SERVERID}-${customer}.xz"

   s3_uri="${BUCKET_PREFIX}-${customer}"

   mysqldump --defaults-file=/etc/piler/.my.cnf -B "$customer" | xz -c > "$f"
   mc -q cp "$f" "$s3_uri"
   rm -f "$f"
}

backup_sphinx() {
   local customer="$1"
   local f
   local s3_uri

   f="${EXPORT_DIR}/main1-${SERVERID}-${customer}.tar.xz"

   s3_uri="${BUCKET_PREFIX}-${customer}"

   pushd "${SPHINX_DATA_DIR}/${customer}" >/dev/null

   tar cfJ "$f" main1.*

   mc -q cp "$f" "$s3_uri"
   rm -f "$f"

   popd >/dev/null
}

main() {
   local customer

   get_server_id
   get_customer_list

   for customer in "${CUSTOMERS[@]}"; do
      log "processing ${customer}"
      backup_customer_dir "$customer" "$ASTORE_DIR" "astore" 256
      backup_customer_dir "$customer" "$STORE_DIR" "store" 2
      backup_database "$customer"
      backup_sphinx "$customer"
   done
}

main "$@"
