# Deploying piler 2.2.5 on a single host

Every component of piler enterprise 2.2.5 on one host with docker compose,
with traefik in front of it for HTTPS (Let's Encrypt certificates).

Your license determines whether it's a no-tenant or multi-tenant deployment.

## Requirements

- A Linux host with Docker and the docker compose plugin
- The hostname in your license (e.g. archive.example.com) pointing to the
  host in DNS: piler-smtp accepts the emails sent to addresses at that
  hostname only. Port 443 reachable from the internet: Let's Encrypt
  checks it
- Port 25 reachable by your mail server: it sends the emails to archive here
- Your license file (license.jwt)

## Install

Copy this directory to the host, then in it:

```
./setup.sh
docker compose up -d --wait
```

`--wait` returns when every service is healthy (about half a minute), or
says which one isn't. `docker compose ps` shows their health later too.

setup.sh asks for the path of your license, the hostname of the archive
(the one in the license), the email address for Let's Encrypt and the mail
relay piler sends emails through (restored emails, notifications). It
writes:

- `.env`: the settings of this installation for docker compose: the
  hostnames, the database passwords, the versions of the images
- `env`: the settings of piler, piler-ui and the scanner, from `env.dist`,
  with a random `JWT_SECRET` and `IMAP_ENCRYPT_KEY`
- `piler.key`: the key the emails are encrypted with
- `license.jwt`, `license.pub`, and the volumes

Back up `piler.key`, `.env` and `env`, outside the host: **without
piler.key the archive can't be read**.

Then open `https://<your hostname>/`, log in as `admin@local` with the
password `pilerrocks`, and change the password.

Without a terminal, setup.sh takes the answers from the environment:

```
PILER_HOSTNAME=archive.example.com ACME_EMAIL=hostmaster@example.com \
LICENSE_FILE=/root/license.jwt SMARTHOST=mail.example.com ./setup.sh
```

It never overwrites `.env`, `env` or `piler.key`. If a step fails, fix the
cause and run it again.

## Settings

Don't edit `docker-compose.yaml` or `traefik-dynamic.yaml`, a newer version
of this example would replace your changes.

- `.env`: the hostnames (`PILER_HOSTNAME`, `TENANT_HOSTNAMES`), the
  Let's Encrypt address and the image versions. Run `docker compose up -d`
  after a change.
- `env`: everything else, see the
  [configuration options](https://docs.mailpiler.com/piler-ee-fiber/fiber-ui-config-options.html).
  Run `docker compose up -d --force-recreate piler piler-ui scanner`
  after a change.

The database passwords are used when the database is created only:
changing them in `.env` doesn't change them in the database.
`MYSQL_PASSWORD` is in both files.

### Tenants

With a multi-tenant license, each tenant has its own hostname. Add it to
`TENANT_HOSTNAMES` in `.env` (comma separated) and run
`docker compose up -d`: traefik gets a certificate of it.

## Upgrade

Read the [upgrade notes](https://docs.mailpiler.com/piler-ee-fiber/upgrade.html)
of every version since yours first, then set `PILER_VERSION` (and
`PILER_SMTP_VERSION`, `SCANNER_VERSION` if they're new) in `.env` and run:

```
docker compose pull
docker compose up -d --wait
```

The piler container adds the `participants` column to the index at its
start (2.2.5).

## Existing installation

An installation set up before setup.sh had its settings in
`docker-compose.yaml`, `env` and `traefik-dynamic.yaml`. setup.sh stops
when it finds the database volume: random passwords would lock piler out
of the existing database. To use the new files:

1. Copy your `env`, `docker-compose.yaml` and `traefik-dynamic.yaml`
   somewhere safe. In this repository `env` became `env.dist`; your `env`
   stays as it is, piler keeps reading it.
2. Create `.env` with the values of your old files:

   ```
   PILER_HOSTNAME=archive.example.com
   TENANT_HOSTNAMES=
   ACME_EMAIL=hostmaster@example.com
   MYSQL_PASSWORD=<the MYSQL_PASSWORD of your docker-compose.yaml>
   MYSQL_ROOT_PASSWORD=<the MYSQL_ROOT_PASSWORD of your docker-compose.yaml>
   PILER_VERSION=2.2.5
   PILER_SMTP_VERSION=1.1.7
   SCANNER_VERSION=1.3.1
   ```

   `PILER_HOSTNAME` is the hostname in your `traefik-dynamic.yaml`, the
   others there go to `TENANT_HOSTNAMES`.
3. If your `env` has no `JWT_SECRET`, add one:
   `echo "JWT_SECRET=$(openssl rand -hex 32)" >> env`
4. Take the new `docker-compose.yaml` and `traefik-dynamic.yaml`, then run
   `docker compose up -d`.

The new `traefik-dynamic.yaml` has no router for the traefik dashboard.

An installation set up before the `piler_error` volume keeps the error
directory in the piler container, and loses it when the container is
recreated. Check it's empty first (`docker exec piler ls /var/piler/error`),
then create the volume: `docker volume create piler_error`.

## Notes

The `aaaaa` database in `docker-compose.yaml` is a placeholder, and it's
required: the MariaDB image needs a database to start, but it can't be
piler's. The piler container creates the `piler` database (and those of the
tenants) only when it doesn't exist yet. Leave it as it is.
