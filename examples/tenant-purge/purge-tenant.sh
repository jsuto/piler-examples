#!/bin/bash
#
# Deletes all the data of a tenant on this node: its database, Manticore
# tables, stored emails, queued files and settings. Run it in the piler
# container (or on a native install) of every node, the workers first,
# then the master. See README.md.
#
# Without --execute it only shows what would be deleted.

set -o errexit
set -o pipefail
set -o nounset

export PATH="/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin"

PILER_CONFDIR="${PILER_CONFDIR:-/etc/piler}"
PILERHOME="${PILERHOME:-/var/piler}"
MY_CNF="${PILER_CONFDIR}/.my.cnf"
MY_CNF_ROOT="${PILER_CONFDIR}/.my.cnf-root"

# The Manticore tables of a tenant, see manticore.sql.dist and
# print-master-node-index.sh. By name: a pattern like 'customer1%' would
# also match customer10.
TABLE_SUFFIXES=("" _tag1 _note1 _cat1 _audit _embeddings _teams_messages _slack_messages)

TENANT=""
EXECUTE=0
ASSUME_YES=0
FORCE_RECENT=0
MASTER_CHECK=1
RECENT_DAYS=7

usage() {
   cat << EOF
Usage: $0 [options] <tenant id>

Deletes all the data of a tenant on this node. Without --execute it only
shows what would be deleted.

Options:
  --execute           Delete the data (asks to type the tenant id)
  --yes               Don't ask, with --execute
  --force-recent      Delete even if the tenant received email in the last
                      ${RECENT_DAYS} days, or has emails waiting in the queue
  --no-master-check   On a worker, don't check the legal holds on the master
                      (only if the master is down for good)
EOF
   exit 1
}

log() {
   echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*"
}

fail() {
   echo "ERROR: $*" >&2
   exit 1
}

while [[ $# -gt 0 ]]; do
   case "$1" in
      --execute) EXECUTE=1 ;;
      --yes) ASSUME_YES=1 ;;
      --force-recent) FORCE_RECENT=1 ;;
      --no-master-check) MASTER_CHECK=0 ;;
      -h|--help) usage ;;
      -*) echo "Unknown option: $1" >&2; usage ;;
      *) [[ -z "$TENANT" ]] || usage; TENANT="$1" ;;
   esac
   shift
done

[[ -n "$TENANT" ]] || usage

# The id goes into SQL and paths: only what create-tenant.sh provisions.
# Without a "-", the queued files <tenant>-* are only this tenant's.
[[ "$TENANT" =~ ^[a-z0-9_]{2,64}$ ]] || fail "invalid tenant id: ${TENANT}"
[[ "$TENANT" != "piler" ]] || fail "the piler tenant is the single-tenant archive and holds the tenant settings, it can't be purged"

[[ $(id -u) -eq 0 ]] || fail "run it as root (docker compose exec piler ...)"
[[ -r "$MY_CNF" && -r "$MY_CNF_ROOT" ]] || fail "${MY_CNF} or ${MY_CNF_ROOT} is missing"

read -r MANTICORE_HOST < "${PILER_CONFDIR}/MANTICORE" || fail "${PILER_CONFDIR}/MANTICORE is missing"

sql() {
   mariadb --defaults-file="$MY_CNF" -N --batch "$@"
}

manticore() {
   mariadb -h "$MANTICORE_HOST" -P9306 -N --batch "$@"
}

# Every check below reads "nothing there" from an empty answer: a database
# that can't be reached must stop the run, not look like a purged tenant
sql -e "SELECT 1" > /dev/null || fail "can't connect to MariaDB with ${MY_CNF}"
manticore -e "SHOW TABLES" > /dev/null || fail "can't connect to Manticore at ${MANTICORE_HOST}:9306"

ROLE="single node"
IS_WORKER=0
if [[ -f "${PILER_CONFDIR}/MASTER" ]]; then
   ROLE="master"
elif [[ -f "${PILER_CONFDIR}/MULTINODES" ]]; then
   ROLE="worker"
   IS_WORKER=1
fi

table_exists() {
   local db="$1"
   local table="$2"
   shift 2

   [[ "$(sql "$@" -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${db}' AND table_name='${table}'")" -gt 0 ]]
}

db_exists() {
   [[ "$(sql "$@" -e "SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name='${TENANT}'")" -gt 0 ]]
}

# Legal holds not released yet ("pending" or "active")
open_legal_holds() {
   if db_exists "$@" && table_exists "$TENANT" legal_hold "$@"; then
      sql "$@" -e "SELECT COUNT(*) FROM \`${TENANT}\`.legal_hold WHERE status IN ('pending', 'active')"
   else
      echo 0
   fi
}

count_files() {
   local n=0
   local f

   for f in "$@"; do
      [[ -e "$f" ]] && n=$(( n + 1 ))
   done

   echo "$n"
}

refuse=()

echo "Tenant ${TENANT} on this node (${ROLE}, $(hostname))"
echo

### Database

has_db=0
if db_exists; then
   has_db=1
   size="$(sql -e "SELECT COALESCE(ROUND(SUM(data_length + index_length) / 1048576), 0) FROM information_schema.tables WHERE table_schema='${TENANT}'")"
   messages=0
   last_arrived=0
   if table_exists "$TENANT" metadata; then
      read -r messages last_arrived < <(sql -e "SELECT COUNT(*), COALESCE(MAX(arrived), 0) FROM \`${TENANT}\`.metadata")
   fi

   if [[ "$last_arrived" -gt 0 ]]; then
      last="$(date -u -d "@${last_arrived}" +%Y-%m-%d\ %H:%M 2>/dev/null || echo "$last_arrived")"
   else
      last="never"
   fi

   echo "Database ${TENANT}: ${size} MB, ${messages} messages, last email: ${last}"

   if [[ "$last_arrived" -gt $(( $(date +%s) - RECENT_DAYS * 86400 )) && $FORCE_RECENT -eq 0 ]]; then
      refuse+=("it received email in the last ${RECENT_DAYS} days: stop the email first (the offboarding steps), or --force-recent")
   fi

   holds="$(open_legal_holds)"
   if [[ "$holds" -gt 0 ]]; then
      refuse+=("${holds} legal holds are not released (Legal hold in the UI)")
   fi
else
   echo "Database ${TENANT}: none"
fi

# The legal holds are made on the master, a worker has them from the hourly
# sync: check the master's, too
if [[ $IS_WORKER -eq 1 && $MASTER_CHECK -eq 1 ]]; then
   master="${MASTER_MYSQL_NODE:-}"
   if [[ -z "$master" && -f "${PILER_CONFDIR}/MASTER_MYSQL_NODE" ]]; then
      read -r master < "${PILER_CONFDIR}/MASTER_MYSQL_NODE"
   fi

   if [[ -z "$master" ]]; then
      refuse+=("the master's database is unknown (MASTER_MYSQL_NODE) to check the legal holds there, or --no-master-check")
   elif ! sql -h "$master" -e "SELECT 1" > /dev/null; then
      refuse+=("can't connect to the master's database (${master}) to check the legal holds there, or --no-master-check")
   elif ! holds="$(open_legal_holds -h "$master")"; then
      refuse+=("can't check the legal holds on the master (${master}), or --no-master-check")
   elif [[ "$holds" -gt 0 ]]; then
      refuse+=("${holds} legal holds are not released on the master (Legal hold in the UI)")
   else
      echo "Legal holds on the master (${master}): none open"
   fi
fi

### Settings

has_settings=0
if table_exists piler tenant_settings && [[ "$(sql -e "SELECT COUNT(*) FROM piler.tenant_settings WHERE tenant_id='${TENANT}'")" -gt 0 ]]; then
   has_settings=1
   echo "Tenant settings: yes (piler.tenant_settings)"
else
   echo "Tenant settings: none"
fi

### Manticore

tables=()
existing="$(manticore -e "SHOW TABLES")"
for s in "${TABLE_SUFFIXES[@]}"; do
   if awk -v t="${TENANT}${s}" '$1 == t { found = 1 } END { exit !found }' <<< "$existing"; then
      tables+=("${TENANT}${s}")
   fi
done
echo "Manticore tables: ${tables[*]:-none}"

### Files

dirs=()
for d in "${PILERHOME}"/store/*/"${TENANT}" "${PILERHOME}"/astore/*/"${TENANT}"; do
   [[ -d "$d" ]] && dirs+=("$d")
done

if [[ ${#dirs[@]} -gt 0 ]]; then
   echo "Directories:"
   du -sh "${dirs[@]}" | sed 's/^/  /'
else
   echo "Directories: none"
fi

shopt -s nullglob
queued=("${PILERHOME}"/tmp/*/"${TENANT}"-*)
staged=("${PILERHOME}"/s3/*/"${TENANT}"-*)
errors=("${PILERHOME}"/error/"${TENANT}"-*)
provisioning=("${PILERHOME}/tenant/${TENANT}")
shopt -u nullglob

echo "Files waiting for the piler daemon: $(count_files "${queued[@]}")"
echo "Files waiting for the S3 upload: $(count_files "${staged[@]}")"
echo "Files in the error directory: $(count_files "${errors[@]}")"

if [[ ${#queued[@]} -gt 0 && $FORCE_RECENT -eq 0 ]]; then
   refuse+=("${#queued[@]} emails wait for the piler daemon: stop the email first, or --force-recent")
fi

echo

if [[ ${#refuse[@]} -gt 0 ]]; then
   for r in "${refuse[@]}"; do
      echo "Refusing: $r" >&2
   done
   exit 1
fi

if [[ $has_db -eq 0 && $has_settings -eq 0 && ${#tables[@]} -eq 0 && ${#dirs[@]} -eq 0 \
      && ${#queued[@]} -eq 0 && ${#staged[@]} -eq 0 && ${#errors[@]} -eq 0 && ! -e "${provisioning[0]}" ]]; then
   echo "Nothing to delete for ${TENANT} on this node."
   exit 0
fi

if [[ $EXECUTE -eq 0 ]]; then
   echo "Dry run, nothing deleted. Run with --execute to delete the above. It can't be undone."
   exit 0
fi

if [[ $ASSUME_YES -eq 0 ]]; then
   read -r -p "This deletes the data of ${TENANT} on this node for good. Type the tenant id to go on: " answer
   [[ "$answer" == "$TENANT" ]] || fail "not confirmed, nothing deleted"
fi

# Every step can be run again: a run that stopped halfway is finished by
# the next one

# piler-ui stops serving the tenant on this node, create-tenant.sh doesn't
# provision it again
if [[ $has_settings -eq 1 ]]; then
   sql -e "DELETE FROM piler.tenant_settings WHERE tenant_id='${TENANT}'"
   log "deleted the tenant settings"
fi
rm -f "${provisioning[0]}"

for t in "${tables[@]}"; do
   manticore -e "DROP TABLE IF EXISTS ${t}"
   log "dropped Manticore table ${t}"
done

if [[ $has_db -eq 1 ]]; then
   mariadb --defaults-file="$MY_CNF_ROOT" -e "DROP DATABASE IF EXISTS \`${TENANT}\`"
   log "dropped database ${TENANT}"
fi

# The grant create-tenant.sh made, kept by MariaDB after the drop
while read -r host; do
   [[ -n "$host" ]] || continue
   # "REVOKE ALL PRIVILEGES, GRANT OPTION" takes no ON clause: two statements
   if mariadb --defaults-file="$MY_CNF_ROOT" -e "REVOKE ALL PRIVILEGES ON \`${TENANT}\`.* FROM 'piler'@'${host}'; REVOKE GRANT OPTION ON \`${TENANT}\`.* FROM 'piler'@'${host}'"; then
      log "revoked the grant of piler@${host} on ${TENANT}"
   else
      echo "WARNING: can't revoke the grant of piler@${host} on ${TENANT}, harmless but left in mysql.db" >&2
   fi
done < <(mariadb --defaults-file="$MY_CNF_ROOT" -N --batch -e "SELECT Host FROM mysql.db WHERE Db='${TENANT}' AND User='piler'")

for d in "${dirs[@]}"; do
   rm -rf -- "$d"
   log "removed ${d}"
done

for f in "${queued[@]}" "${staged[@]}" "${errors[@]}"; do
   rm -f -- "$f"
done
if [[ $(( ${#queued[@]} + ${#staged[@]} + ${#errors[@]} )) -gt 0 ]]; then
   log "removed $(( ${#queued[@]} + ${#staged[@]} + ${#errors[@]} )) queued and error files"
fi

bucket_prefix="${S3_BUCKET_PREFIX:-}"
if [[ -z "$bucket_prefix" && -r "${PILERHOME}/.env" ]]; then
   bucket_prefix="$(sed -n 's/^S3_BUCKET_PREFIX=//p' "${PILERHOME}/.env" | tail -1 | tr -d '"'"'")"
fi

cat << EOF

Done on this node. Still to do:
- Run it on the other nodes: the workers first, the master last.
- With S3 storage, delete the bucket ${bucket_prefix}${TENANT} and its objects
  once every node is done, e.g. mc rb --force <alias>/${bucket_prefix}${TENANT}
- Remove the tenant from your monitoring and billing.
- Your backups keep the data until they expire.
EOF
