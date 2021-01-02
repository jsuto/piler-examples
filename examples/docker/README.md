# Deploying piler enterprise to docker with docker-compose

## The layout

This setup features the following containers:

* traefik: http and https entry point
* mariadb: storing metadata, user db, etc.
* memcached: to cache some data
* Apache tika: to extract textual attachment data
* Piler enterprise 1.5.0: the email archive running piler and sphinxsearch

Port mappings to containers:

- traefik: 80/tcp, 443/tcp
- piler: 25/tcp

No other port should be visible from the outside.

## Prerequisites

* Get the license file to run piler enterprise

## Setup

### Customize traefik.yaml

Edit traefik.yaml and replace admin@yourdomain.com and archive.yourdomain.com
with your email and archive hostname.

The acme.json file must be owned by root:root and have 0600 permissions:

```
chmod 600 acme.json
chown root:root acme.json
```

### Customize docker-compose.yaml

Fix following values:

* MYSQL_PILER_PASSWORD
* MYSQL_ROOT_PASSWORD
* PILER_HOSTNAME
* MULTITENANCY


## Execute

docker-compose up -d

## Final words

You just got a https enabled piler deployment in a containerized environment.
