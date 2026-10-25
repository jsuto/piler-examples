# Deploying piler enterprise to docker with docker-compose

## The layout

This setup features the following containers:

* traefik: http and https entry point
* mariadb: storing metadata, user db, etc.
* memcached: to cache some data
* Apache tika: to extract textual attachment data
* Piler enterprise 1.8.4: the email archive running piler
* Manticoresearch: the search engine

Port mappings to containers:

- traefik: 443/tcp
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


If you preferred external volumes rather than docker-compose managed volumes,
then fix the volumes section at the end:

```
...

volumes:
  db_data:
    external: true
    name: db-data
  piler_etc:
    external: true
    name: piler-etc
  piler_mantiocore:
    external: true
    name: piler-manticore
  piler_store:
    external: true
    name: piler-store
  piler_astore:
    external: true
    name: piler-astore
```


## Execute

```
docker compose up -d
```

## Final words

You just got a https enabled piler deployment in a containerized environment.

## Piler open source edition

If you want piler open source edition in a dockerized environment, then
check out the [piler source directory](https://github.com/jsuto/piler/tree/master/docker).
