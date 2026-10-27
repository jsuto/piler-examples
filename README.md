# Examples of piler configurations

## Piler enterprise 2.2 deployments

* [Single node](examples/v2.2/single-node/): every component on one host,
  no-tenant or multi-tenant, depending on the license
* [Multi-node, multi-tenant](examples/v2.2/multinode-multitenant/): a master
  and several workers on separate hosts, emails in S3-compatible storage,
  for hosting providers and MSPs

## Monitoring

* [Monitoring](examples/monitoring/): piler-ui's metrics, alert rules
  (Prometheus format, with tests), and a Grafana Cloud setup with Alloy and
  a dashboard

## Hosting

* [Purging a tenant](examples/tenant-purge/): delete a tenant's database,
  index, stored emails and settings on every node, with safety checks

## Mail flow, TLS, security

* [Postfix as MX](examples/postfix-mx/): receive the journal emails and pass
  them to piler
* [Let's Encrypt with Traefik](examples/lets-encrypt-with-traefik/): an
  A-grade TLS setup
* [OWASP ModSecurity WAF](examples/waf/) in front of piler

## Backup

* [Raw data to an S3 bucket](examples/backup-raw-data-to-s3-bucket/)
* [Daily export to an S3 bucket](examples/backup-daily-export-to-s3-bucket/)

## Older versions

The examples of piler 2.0 and 2.1, and the first Docker setups, are in
[archive](examples/archive/). Use the 2.2 examples for new deployments.
