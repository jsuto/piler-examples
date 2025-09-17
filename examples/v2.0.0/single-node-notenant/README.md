# Deploying a no-tenant piler with new UI

## Create the external volumes

```
docker volume create piler_db
docker volume create piler_manticore
docker volume create piler_etc
docker volume create piler_store
docker volume create piler_astore
docker volume create piler_traefik
```

## Get the licenses for both the UI and the archive

## Customise files with your passwords, domain names
