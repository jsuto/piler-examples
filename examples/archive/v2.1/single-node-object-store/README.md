# Deploying piler 2.1.1 with new UI

This docker compose stack gives you complete piler enterprise v2.1.1 deployment
including traefik reverse proxy to provide you an A-grade TLS certificate for https.

It also stores emails in a local minio object store.

Your license determines whether it's a no-tenant or multi-tenant deployment.

## Create the external volumes

```
docker volume create piler_db
docker volume create piler_manticore
docker volume create piler_etc
docker volume create piler_store
docker volume create piler_astore
docker volume create piler_s3
docker volume create piler_minio
docker volume create piler_tmp
docker volume create piler_traefik
```

## Get the license JWT file

Also download the public key for the license:

```
curl -o license.pub https://download.mailpiler.com/license.pub
```

## Create the encryption key

```
dd if=/dev/urandom bs=64 count=1 of=piler.key
```

## Customise files with your passwords, domain names

Edit docker-compose.yaml, and perform any customisation you need, change the default passwords, etc.

Edit traefik-dynamic.yaml and set your own hostnames for the archive.

## Run the docker compose stack

```
docker compose up -d
```

## Notes

Don't change the default mysql database ("aaaaa"), it's intentional.
