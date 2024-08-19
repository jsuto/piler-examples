# Deploying multiple piler enterprise containers

## The layout

This setup features the following containers:

* mariadb: storing metadata, user db, etc.
* memcached: to cache some data
* Apache tika: to extract textual attachment data
* Piler enterprise 1.8.4: the email archive running piler
* Manticoresearch: the search engine
* syslog: collect logs from each host

Port mappings to containers:

- archive.example.com: 80/tcp
- worker0: 2520/tcp -> 25/tcp
- worker1: 2521/tcp -> 25/tcp

No other port should be visible from the outside.

## Prerequisites

* Get the license files for both worker0 and worker1 containers

## Setup

### Customize docker-compose.yaml

Be sure to change passwords, the auth code, and increase the
memory limits. Also replace archive.example.com hostname.

## Execute

```
docker compose up -d
```
