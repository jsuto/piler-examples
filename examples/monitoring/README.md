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

Requires piler-ee 2.2.6 or later for the tenant metrics and the
`X-Forwarded-For` handling described below.

## What to scrape

| Deployment | Targets |
|---|---|
| Single node | piler-ui (port 3000) |
| Multi-node | The master's piler-ui (its own process, database and HTTP metrics) and **every worker's piler-ui** (port 3000 on the private network): the tenant metrics come from the workers, where the emails and indexes are |

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
