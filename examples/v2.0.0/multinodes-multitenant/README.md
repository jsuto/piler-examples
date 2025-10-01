# Deploying a multi-tenant, multi-nodes environment with new UI

This docker compose stack gives you a multi-tenant deployment of piler enterprise v2.0.0
including traefik reverse proxy to give you an A-grade TLS certificate for https

The setup includes 1 master node, and 1 worker node. The 2 nodes share an internal network,
10.0.0.0/24. The master node has 10.0.0.2, while the worker node has 10.0.0.3.

## Create the external volumes

```
docker volume create piler_db
docker volume create piler_manticore
docker volume create piler_etc
docker volume create piler_store
docker volume create piler_astore
docker volume create piler_tmp
docker volume create piler_traefik
```

## Get the licenses for both the UI and the archive

You need licenses for both the master and the worker nodes.

## Customise files with your passwords, domain names

Edit docker-compose.yaml, and perform any customisation you need.

## Run the docker compose stack

```
docker compose up -d
```

## Notes

In docker-compose.yaml notice the double $$ symbols in the admin password hash.
It's a yaml workaround to specify $ symbol in the hash value.


TODO: network layout
