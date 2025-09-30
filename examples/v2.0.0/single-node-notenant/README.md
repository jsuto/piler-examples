# Deploying a no-tenant piler with new UI

This docker compose stack gives you a no-tenant deployment of piler enterprise v2.0.0
including traefik reverse proxy to give you an A-grade TLS certificate for https

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

## Customise files with your passwords, domain names

Edit docker-compose.yaml, and perform any customisation you need.

## Run the docker compose stack

```
docker compose up -d
```
