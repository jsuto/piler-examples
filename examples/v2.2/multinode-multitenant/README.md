# Multi-node, multi-tenant piler 2.2

A piler enterprise deployment for many tenants on several hosts: one master
node and any number of worker nodes, the emails stored in S3-compatible
object storage. It follows the conventions of the
[single-node example](../single-node/).

Tested with piler-ee 2.2.5, piler-smtp 1.1.7 and scanner 1.3.1, one master
and two workers.

## The layout

```
        the tenants' mail servers (journaling)
               │ SMTP :25            │ SMTP :25
        ┌──────▼───────┐      ┌──────▼───────┐
        │   worker0    │      │   worker1    │ ...   piler-smtp, piler, s3uploader,
        │              │      │              │       MariaDB, Manticore, piler-ui
        └──┬────────▲──┘      └──┬────────▲──┘
   emails  │        │ :3000 API  │        │ :9312 index
           ▼        └─────┬──────┴────────┘
   ┌──────────────┐ ┌─────┴────────────────┐
   │  S3 storage  │ │        master        │  piler-ui, MariaDB,
   │ bucket/tenant│ │ :3306, :9307 for the │  Manticore (distributed),
   └──────────────┘ │ workers' rule sync   │  Traefik
                    └─────────▲────────────┘
                              │ :443
                       users, REST API
```

- **Workers** receive the emails, archive them to S3 and index them in
  their own MariaDB and Manticore. Each keeps the emails it archived. Add
  workers as the mail volume grows.
- **The master** runs the web UI and the REST API of every tenant. It stores
  no email: its distributed Manticore tables query the workers' indexes, and
  it fetches the messages from the workers' piler-ui.

The two directories are one compose project each: copy `master/` to the
master host and `worker/` to every worker host.

## Network

The nodes talk to each other on a **private network** (a VLAN, a cloud
private network, or WireGuard between the hosts). This traffic is not
encrypted and not authenticated beyond the database passwords, so these
ports must never be reachable from the internet. Each node publishes them
only on its `PRIVATE_IP`.

| Port | On | From | What |
|---|---|---|---|
| 443 | master | users | web UI, REST API (Traefik) |
| 25 | workers | the tenants' mail servers | piler-smtp |
| 3000 | workers | master | the worker's piler-ui: search results, messages |
| 9312 | workers | master | the worker's Manticore, for the distributed tables |
| 3306 | master | workers | MariaDB: the workers copy the tenants' rules hourly |
| 9307 | master | workers | Manticore read-only: the workers copy the categories |

Restrict port 25 to the mail servers sending to piler (firewall, or
`smtp_access_list` in `piler.conf`), especially when envelope files are
enabled.

## Before you start

- **Hosts and names.** One host for the master and one per worker, with
  Docker and the compose plugin. Each node needs a name the others resolve
  to its private address, e.g. `master.example.internal`,
  `worker0.example.internal`.
- **A license per node.** The master's license and one per worker, each
  with its own server id (`00`, `01`, ...). piler-smtp accepts only the
  recipients `@<the hostname of its license>`, so a worker's archive
  addresses are `<tenant>@<that hostname>`: ask for the worker licenses with
  the names the mail servers will send to.
- **The encryption key**, the same on every node:

  ```
  dd if=/dev/urandom bs=64 count=1 of=piler.key
  ```

  Keep a copy outside the deployment: without it the archive can't be read.
- **S3 storage** with an access key. piler stores the emails of a tenant
  in the bucket `S3_BUCKET_PREFIX` + tenant id. **s3uploader doesn't create
  buckets**: create the bucket before the tenant's first email (see
  [Adding a tenant](#adding-a-tenant)).
- **Secrets that must match**: the MariaDB `piler` password (the workers
  log in to the master's database with it), `JWT_SECRET` (the master passes
  the user's token to the workers) and `IMAP_ENCRYPT_KEY`.

## Set up the master

On the master host, in the `master/` directory:

1. Copy `piler.key` and the master's license (`license.jwt`) here.
2. Edit `.env`: `PRIVATE_IP`, `PILER_HOSTNAME`, the workers in `WORKERS`
   and `MANTICORE_WORKERS` in the order of their server id, the passwords
   and secrets, `ACME_EMAIL`.
3. Edit `piler.env` (UI settings, smarthost for restores) and
   `traefik-dynamic.yaml` (your hostnames).
4. Create the volumes and start it:

   ```
   for v in piler_db piler_manticore piler_tenant piler_traefik; do docker volume create $v; done
   docker compose up -d
   ```

## Set up a worker

On every worker host, in a copy of the `worker/` directory:

1. Copy `piler.key`, the worker's own license (`license.jwt`) and the
   license public key:

   ```
   curl -o license.pub https://download.mailpiler.com/license.pub
   ```

2. Edit `.env`: `WORKER_NAME`, `PRIVATE_IP`, `MASTER_HOST`, the passwords
   and secrets, the S3 settings.
3. Create the volumes and start it:

   ```
   for v in piler_db piler_manticore piler_tmp piler_store piler_astore piler_s3 piler_tenant piler_error; do docker volume create $v; done
   docker compose up -d
   ```

Start the workers before the master: at startup the master checks the
index through the workers, and only logs a warning if it can't reach them.

## Adding a tenant

A tenant is created on **every node**: the master and each worker, with
the same tenant id, domain and `gui_url`.

1. **Create the bucket** `S3_BUCKET_PREFIX` + tenant id in your S3 storage.
2. **Add the tenant on the master** (admin UI, or the REST API), then on
   **each worker** through its piler-ui on port 3000:

   ```
   TOKEN=$(curl -s -X POST -H "Host: worker0.example.internal" -H 'Content-Type: application/json' \
      -d '{"username":"admin@local","password":"<admin password>"}' \
      http://worker0.example.internal:3000/auth/login | jq -r .access_token)

   curl -s -X POST -H "Host: worker0.example.internal" -H "Authorization: Bearer $TOKEN" \
      -H 'Content-Type: application/json' \
      -d '{"tenant_id":"customer1", "domain":"customer1.com", "gui_url":"customer1.archive.example.com",
           "admin_password":"<tenant admin password>", "archive_address":"customer1@worker0.example.internal",
           "enable_purge":1, "retention_days":3650, "settings_json":"{}"}' \
      http://worker0.example.internal:3000/api/v1/admin/tenant/add
   ```

3. The databases and indexes are created by cron within 15 minutes, or at
   once on each node:

   ```
   docker compose exec piler su piler -c /usr/libexec/piler/create-tenant.sh
   ```

4. **Add a Traefik router** for the tenant's `gui_url` in
   `traefik-dynamic.yaml` on the master.
5. **Point the tenant's journaling** at `customer1@worker0.example.internal`
   (and the other workers, if the mail is spread among them). piler-smtp
   accepts the emails of a tenant once its store directory exists on that
   worker, after step 3.
6. **Create the users.** The tenant's `admin@local` administers the tenant
   but can't search email: add auditors, or let the users log in with LDAP,
   Entra ID, IMAP etc.

If emails arrived before the bucket existed, s3uploader moved them to its
error directory. Create the bucket, then move them back on that worker:

```
docker compose exec s3uploader sh -c 'mv /var/piler/error/*.m /var/piler/s3/0/'
```

## Adding a worker

1. Set up the new worker as above, with a license with the next server id.
2. Add the tenants on it (step 2 and 3 of [Adding a tenant](#adding-a-tenant)).
3. On the master, append it to `WORKERS` and `MANTICORE_WORKERS` in `.env`
   (keep the order of the server ids), and recreate the containers:

   ```
   docker compose up -d
   ```

4. Recreate the distributed tables of every tenant on the master, so they
   query the new worker too. Only the distributed tables: `_audit` and
   `_cat1` hold data.

   ```
   docker compose exec piler sh -c '
   for t in piler $(mariadb --defaults-file=/etc/piler/.my.cnf -N piler -e "select tenant_id from tenant_settings where tenant_id != \"piler\""); do
      for s in "" _tag1 _note1 _embeddings; do echo "DROP TABLE IF EXISTS ${t}${s};"; done
      /usr/libexec/piler/print-master-node-index.sh "$t" | grep distributed
   done | mariadb -h manticore -P9306'
   ```

## Monitoring

See the [monitoring example](../../monitoring/): scrape the master's
piler-ui and every worker's piler-ui (port 3000 on the private network),
the tenant metrics come from the workers. `ALLOWED_CIDRS` (worker `.env`,
master `piler.env`) must include the scraper's address.

## Upgrading

Upgrade the workers first, then the master: set `PILER_VERSION` in `.env`
and run

```
docker compose pull
docker compose up -d
```

Read the [upgrade notes](https://docs.mailpiler.com/piler-ee-fiber/upgrade.html)
of the version first.

A worker set up before the `piler_error` volume keeps its error directory
in the containers, and loses it when they are recreated. Before the
upgrade, check it's empty (`docker compose exec piler ls /var/piler/error`,
the same for `s3uploader`), move what's there back for processing, then
`docker volume create piler_error`.

## Notes

- Don't change the default MariaDB database (`aaaaa`), it's intentional.
- For a local test of S3 storage, `sutoj/minio:RELEASE.2025-07-23` works
  (MinIO no longer publishes images); in production use your S3 service.
- To make the MariaDB data encrypted at rest, see `ENCRYPTED_SQL` and the
  [multiple-nodes example](../../archive/docker/multiple-nodes-with-multitenancy/install.sh).
