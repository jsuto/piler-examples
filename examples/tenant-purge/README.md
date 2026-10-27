# Purging a tenant

Removing a tenant in **Admin > Tenant** only removes its settings: its
archive stays on every node. [purge-tenant.sh](purge-tenant.sh) deletes the
rest on one node:

- the tenant's MariaDB database, and the grant of the `piler` user on it
- its Manticore tables (`<tenant>`, `_tag1`, `_note1`, `_cat1`, `_audit`,
  `_embeddings`, `_teams_messages`, `_slack_messages`)
- its directories in the store and the attachment store
- its emails waiting in `/var/piler/tmp`, `/var/piler/s3` and
  `/var/piler/error`
- its row in `piler.tenant_settings`, and its provisioning request

It's the last step of [offboarding a tenant](https://docs.mailpiler.com/piler-ee-fiber/hosting/offboarding/):
export the archive and stop the email first. It can't be undone, your
backups keep the data until they expire.

Requires piler-ee 2.2 (multi-tenant), and runs in the `piler` container or
on a native install.

## Safety checks

Without `--execute` the script only shows what it would delete. It refuses
to delete when:

- the tenant has a legal hold that is not released (pending or active). On
  a worker it also checks the master, where the legal holds are made (the
  workers get them from an hourly sync)
- the tenant received email in the last 7 days, or has emails waiting for
  the piler daemon: the email is still coming in (`--force-recent` to
  delete anyway, e.g. for a test tenant)
- MariaDB, Manticore or, on a worker, the master's database can't be
  reached: an answer it can't get would look like nothing to delete
- the tenant id isn't a valid one (`a-z0-9_`), or it's `piler`

With `--execute` it asks to type the tenant id (`--yes` skips this). Every
step can be run again: if a run stops halfway, the next one finishes it.

## Running it

On **every node**, the workers first, then the master (a single node: just
the one). On a host, in the directory of the node's `docker-compose.yaml`:

```
docker compose cp purge-tenant.sh piler:/tmp/purge-tenant.sh

# What would be deleted
docker compose exec piler bash /tmp/purge-tenant.sh customer1

# Delete it
docker compose exec piler bash /tmp/purge-tenant.sh --execute customer1
```

On a native install, as root: `bash purge-tenant.sh customer1`.

A dry run prints something like:

```
Tenant customer1 on this node (worker, worker0)

Database customer1: 2140 MB, 1834201 messages, last email: 2026-09-27 06:33
Legal holds on the master (master.example.internal): none open
Tenant settings: yes (piler.tenant_settings)
Manticore tables: customer1 customer1_tag1 customer1_note1 customer1_cat1 customer1_audit customer1_embeddings customer1_teams_messages customer1_slack_messages
Directories:
  4.0K	/var/piler/store/00/customer1
  4.0K	/var/piler/astore/00/customer1
Files waiting for the piler daemon: 0
Files waiting for the S3 upload: 0
Files in the error directory: 0

Dry run, nothing deleted. Run with --execute to delete the above. It can't be undone.
```

## Afterwards

- With S3 storage, delete the tenant's bucket (`S3_BUCKET_PREFIX` + tenant
  id) and its objects once every node is done, e.g.
  `mc rb --force <alias>/<bucket>`. The script doesn't: the piler container
  has no S3 client, and a bucket is the one thing the script can't check
  belongs to this tenant only.
- Remove the tenant from your monitoring and billing.
- The `_audit` table holds who accessed the archive. If your compliance
  rules require keeping it after the contract, export it first (**Audit >
  Export** as an auditor).

## Options

| Option | Meaning |
|---|---|
| `--execute` | Delete the data, after typing the tenant id |
| `--yes` | Don't ask, with `--execute` |
| `--force-recent` | Delete even if the tenant received email in the last 7 days, or has emails waiting in the queue |
| `--no-master-check` | On a worker, don't check the legal holds on the master: only if the master is gone for good |
