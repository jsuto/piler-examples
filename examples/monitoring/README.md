# Monitoring piler

piler-ui exposes its metrics in the Prometheus text format at `/metrics`,
and a health check at `/healthz`. Any monitoring system that reads
Prometheus metrics can use them. This example has:

- [prometheus/piler-alerts.yaml](prometheus/piler-alerts.yaml): alert rules
  in the Prometheus rule format, with [tests](prometheus/piler-alerts.test.yaml)
- [prometheus/prometheus.yaml](prometheus/prometheus.yaml): a scrape
  configuration
- [grafana-cloud/](grafana-cloud/): Grafana Alloy sending the metrics (and
  optionally the logs and host metrics) to Grafana Cloud, and a dashboard

Grafana Cloud is one option, not a requirement: the metrics, the alert
conditions and the dashboard queries below work in any Prometheus-compatible
system, and the table of alerts translates to other platforms.

Requires piler-ee 2.2.6 or later for the tenant, quota and pipeline metrics and
the `X-Forwarded-For` handling described below.

## What to scrape

| Deployment | Targets |
|---|---|
| Single node | piler-ui (port 3000) |
| Multi-node | The master's piler-ui (its own process, database and HTTP metrics, and the quotas) and **every worker's piler-ui** (port 3000 on the private network): the tenant metrics come from the workers, where the emails and indexes are |

Label the targets with `role` (`single`, `master`, `worker`), the alert
rules use it.

### Access

`/metrics` and `/healthz` answer only the addresses in piler-ui's
`ALLOWED_CIDRS` (default: `127.0.0.0/8` and the Docker networks
`172.18-20.0.0/16`). Add your scraper's address, e.g. the private network
of a multi-node deployment:

```
ALLOWED_CIDRS=127.0.0.0/8,172.16.0.0/12,10.0.0.0/24
```

Scrape piler-ui directly, not through the reverse proxy. A request through
a proxy counts only if the proxy is in `TRUSTED_PROXIES`, and then the
client is the address in the proxy's `PROXY_HEADER` (default
`X-Forwarded-For`, set `PROXY_HEADER=X-Real-IP` for a proxy sending only
that). A forwarded request from any other address is refused.

## The metrics

The values are kept in Redis for 5 minutes: a metric that piler-ui stops
updating disappears after 5 minutes.

### Per tenant

Collected every minute, on a single node and on the workers. A multi-node
deployment has a series per tenant and worker: sum them by `tenant`.

| Metric | Meaning |
|---|---|
| `piler_tenant_messages_received{tenant}` | Messages received, all time. Only grows while the tenant's email arrives. |
| `piler_tenant_messages_purged{tenant}` | Messages removed by retention purges, all time |
| `piler_tenant_size_bytes{tenant}` | Original size of the archived email, now (purged email excluded) |
| `piler_tenant_stored_bytes{tenant}` | Stored (compressed, encrypted) size of the archived email, now |
| `piler_index_documents{tenant}` | Documents in the tenant's Manticore index |
| `piler_index_disk_bytes{tenant}`, `piler_index_ram_bytes{tenant}` | Size of the tenant's index on disk and in RAM |
| `piler_tenant_metrics_last_success_timestamp_seconds` | Unix time of the last collection in which every query succeeded |

The size and stored bytes are what a hoster bills and plans capacity by.

### Quotas (multi-tenant)

From the quota snapshot the master collects every `QUOTA_SNAPSHOT_INTERVAL`
(15 minutes): on the master's piler-ui (the leader's, and with several
masters every master serves the same values), or a single node's. Not on
the workers, they have only their share of the usage.

| Metric | Meaning |
|---|---|
| `piler_tenant_quota_used{tenant,quota}` | The tenant's usage: `quota="storage"` in bytes, `"emails"`, `"users"` (active users: received email in the last 90 days) |
| `piler_tenant_quota_limit{tenant,quota}` | The tenant's quota; no series for a quota not set (unlimited) |
| `piler_tenant_quota_age_seconds{tenant}` | Age of the tenant's usage |
| `piler_quota_snapshot_age_seconds` | Age of the last snapshot |

When a worker doesn't answer the master, the usage of the others is too
low: the gauges keep the tenant's last usage collected from every worker,
and its age grows. These values don't expire after 5 minutes: when the
snapshot stops, the ages grow. A tenant whose usage was never collected
completely has no series.

### Archiving pipeline

The piler daemon and s3uploader write these to the Redis of `REDIS_ADDR`
(the setting of piler-ui, in the same `.env`) every 15 seconds, and
piler-ui serves them: on a multi-node deployment each worker's piler-ui
has those of its own node, from the worker's own Redis. If Redis is down,
the daemons keep archiving and uploading, the counts are written when it's
back. A restarted daemon continues its counters; after more than 5
minutes down they start from 0 again, a counter reset that `rate()` and
`increase()` handle.

| Metric | Meaning |
|---|---|
| `piler_archive_messages_total{result}` | Emails the piler daemon processed (counter): `archived`, `duplicate`, `discarded` (by an exclusion rule), `error` (not archived: moved to the error directory, or, if it can't be moved, left in the queue and counted again at every retry) |
| `piler_queue_files` | Emails waiting in the worker directories (`/var/piler/tmp/<n>`) |
| `piler_error_dir_files` | Files in the error directory (`/var/piler/error`), counted by the piler daemon. s3uploader moves the files it couldn't upload to the same directory on a native install and with the Docker examples (the `piler_error` volume). |
| `piler_s3_uploads_total{result}` | Files s3uploader handled (counter): `uploaded`, `error` (not uploaded after the retries) |
| `piler_s3_queue_files`, `piler_s3_queue_bytes` | Files and bytes waiting for the upload (`/var/piler/s3`): set at every scan of the queue, lowered as the files are uploaded |
| `piler_s3_queue_oldest_age_seconds` | Age of the oldest file at the last scan of the queue, 0 if none. With a large backlog the scans are far apart, and that file may have been uploaded since: an upper bound. |

The directories are counted every minute by their names only, without a
`stat` of every file, so the count stays cheap with a large backlog. The
count stops at 100000: past that the gauge stays at 100000. The rate of
the errors comes from the counters, not from the directory: the alert fires
at the first failed email.

### piler-ui, database, cache

| Metric | Meaning |
|---|---|
| `http_requests_total{method,status}`, `http_requests_by_status_class{class}` | HTTP requests (counters) |
| `http_request_duration_seconds` | Request time (histogram) |
| `disk_size_bytes`, `disk_used_bytes` | The disk of the email store (`PILER_STORE_DIR`) as piler-ui sees it |
| `db_connections_active`, `db_connections_max`, `db_connections_utilization_percent` | MariaDB connections |
| `db_response_time_milliseconds`, `db_slow_queries_total`, `db_size_bytes` | MariaDB response time, slow queries, size of the piler database |
| `db_replication_lag_seconds`, `db_replication_running` | Only with MariaDB replication |
| `redis_memory_used_bytes`, `redis_hit_rate_percent`, `redis_evicted_keys_total` | Redis (sessions and caches) |
| `process_memory_heap_inuse_bytes`, `process_goroutines` | The piler-ui process |

With S3 storage the store disk is small: monitor the volumes of MariaDB
and Manticore on every host with a host exporter (node_exporter, or
`host.alloy` in the Grafana Cloud example).

## What to alert on

The rules in [piler-alerts.yaml](prometheus/piler-alerts.yaml):

| Alert | Condition | Why |
|---|---|---|
| `PilerDown` | `up == 0` for 5 minutes | piler-ui is down, or the scraper isn't allowed |
| `PilerTenantJournalingStopped` | A tenant's received count didn't grow in 6 hours | The customer's journaling rule or the path to piler-smtp broke: email is being lost from the archive |
| `PilerTenantMetricsMissing` | A single node or worker answers, but has no tenant metrics for 15 minutes | The collector fails, piler-ui logs the tenant (`tenant metrics: ...`) |
| `PilerArchivingErrors` | The daemon couldn't archive emails in the last 10 minutes | Those emails are not in the archive. The daemon's log has the reason (`status=error`) |
| `PilerErrorDirectoryNotEmpty` | The error directory has files for an hour | Emails left there from an earlier failure: move them back for processing |
| `PilerArchivingStalled` | Emails wait in the worker directories, and the daemon processed none for 20 minutes | The daemon is stuck or stopped, e.g. MariaDB or Manticore is down |
| `PilerQueueBacklog` | Over 10000 emails wait for 30 minutes | The daemon is slower than the email arrives. Tune the threshold to your volume |
| `PilerPipelineMetricsMissing` | A single node or worker answers, but the daemon wrote no metrics for 15 minutes | The daemon doesn't run, or can't reach Redis |
| `PilerS3UploadErrors` | s3uploader couldn't upload files in the last 10 minutes | The S3 setup broke (bucket, policy, credentials): the archive can't read these emails |
| `PilerS3UploadBacklog` | The oldest file waits for the upload for over an hour | S3 is unreachable or too slow; until the upload the email is only on the local disk |
| `PilerS3UploaderMetricsMissing` | s3uploader wrote metrics in the last day, but none for 15 minutes | s3uploader doesn't run, or can't reach Redis |
| `PilerTenantQuotaExceeded` | A tenant is over a quota for an hour | Raise the quota or bill the overage |
| `PilerTenantQuotaNearLimit` | A tenant uses over 90% of a quota for an hour (info) | The tenant's own warning thresholds are in its quota emails |
| `PilerQuotaSnapshotStale` | The quota snapshot is over an hour old | The master's snapshot job fails: the quota dashboard, the emails and these metrics are stale |
| `PilerTenantQuotaUsageStale` | The usage of some tenants is over an hour old, the snapshot isn't | A worker doesn't answer the master: the quota alerts use the last complete usage |
| `PilerDiskAlmostFull` | The store disk is 85% full | |
| `PilerDatabaseConnectionsHigh` | Over 80% of MariaDB's connections in use | |
| `PilerHTTPErrors` | Over 5% of the requests end with 5xx | |
| `PilerSlowRequests` | The 95th percentile of the request time is over 5 s | |

Tune the thresholds to your tenants: a tenant with little email may be
quiet for 6 hours on a weekend. After changing a rule, run its tests:

```
promtool test rules prometheus/piler-alerts.test.yaml
```

The `/healthz` endpoint answers `503` when MariaDB, Manticore or Redis is
down: a blackbox HTTP check on it (see `prometheus.yaml`) complements
`PilerDown`.

## Prometheus

Copy `prometheus/prometheus.yaml` and `prometheus/piler-alerts.yaml` next
to each other, list your piler-ui targets, and route the alerts through
Alertmanager as usual.

## Grafana Cloud

1. In your Grafana Cloud stack, create an access policy token with
   `metrics:write` (and `logs:write` for the logs). The Prometheus and Loki
   URLs and user ids are under **Connections**.
2. Copy `grafana-cloud/` to the host running piler (on a multi-node
   deployment the master: it reaches the workers on the private network).
3. Fill in `grafana-cloud/.env`: the URLs, user ids and token,
   `PILER_DEPLOYMENT` (a label to tell deployments apart) and
   `PILER_NETWORK` (piler's Docker network: `piler` for the single-node
   example, `piler-master` on the master of the multi-node example).
4. List the targets in `grafana-cloud/alloy/metrics.alloy`. `logs.alloy`
   sends the container logs, `host.alloy` the host's CPU, memory and disks:
   delete the ones you don't need. On a multi-node deployment run Alloy on
   each worker too for its logs and host metrics, with the piler targets
   removed from its `metrics.alloy`.
5. Start it:

   ```
   cd grafana-cloud
   docker compose up -d
   ```

6. Import the dashboard: **Dashboards > New > Import**, upload
   `grafana-cloud/piler-dashboard.json`, pick your Prometheus data source.
7. Load the alert rules into your stack's ruler with
   [mimirtool](https://grafana.com/docs/mimir/latest/manage/tools/mimirtool/):

   ```
   (echo "namespace: piler"; cat prometheus/piler-alerts.yaml) > piler-rules.yaml
   mimirtool rules load piler-rules.yaml \
      --address=https://prometheus-prod-XX-prod-eu-west-2.grafana.net/api/prom \
      --id=<Prometheus user id> --key=<token with rules:write>
   ```

   Then route them under **Alerting > Contact points / Notification
   policies**.

The dashboard shows the email received per tenant, the archive and index
size per tenant, a table of the current values per tenant (for billing),
and the health of every piler-ui.

## Other platforms

Most monitoring systems read the Prometheus text format: point them at
`http://<piler-ui>:3000/metrics` from an address in `ALLOWED_CIDRS`, and
recreate the conditions of the alert table above. For example: Datadog
(OpenMetrics check), Zabbix (HTTP agent item with Prometheus preprocessing),
Checkmk (Prometheus special agent), Elastic (Prometheus module),
VictoriaMetrics (vmagent and vmalert, which run the rule file as is).
