# Deploying piler on a single host

Every component of piler enterprise on one host with docker compose,
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

Update the example first (`git pull`), a new release may need its newer
files. Then, in this directory:

```
../../../scripts/piler-upgrade.sh           # your versions, and the newer releases
../../../scripts/piler-upgrade.sh 2.3.1     # upgrade piler-ee
```

`piler-upgrade.sh` is in `scripts/` of this repository. On a host with a
copy of the example only, download it:
`curl -fsSLO https://raw.githubusercontent.com/jsuto/piler-examples/master/scripts/piler-upgrade.sh && chmod +x piler-upgrade.sh`

It shows the [upgrade notes](https://docs.mailpiler.com/piler-ee-fiber/upgrade/)
of every release since yours and asks before it does anything; a release
with an upgrade step needs your confirmation that it's done. Then it pulls
the new images, dumps the database and copies `.env` and `env` into
`backups/`, sets the versions in `.env`, and starts the new containers and
waits until they're healthy. If they don't get healthy, it prints how to
go back. It doesn't downgrade.

`--smtp <version>` and `--scanner <version>` upgrade piler-smtp and the
scanner too, `--yes` doesn't ask (for a script), `--no-backup` skips the
database dump. `backups/` isn't cleaned up: remove the old ones yourself.

By hand: set `PILER_VERSION` (and `PILER_SMTP_VERSION`, `SCANNER_VERSION`)
in `.env`, then `docker compose pull` and `docker compose up -d --wait`.

The piler container adds the `participants` column to the index at its
start (2.2.5).

An installation set up before traefik got its fixed address (172.31.250.10)
has `TRUSTED_PROXIES=172.16.0.0/12` in `env`: set it to `172.31.250.10`.
The next `docker compose up -d` recreates the `piler` network with its
fixed subnet.

## Backup

`../../../scripts/piler-backup.sh` backs up the installation into a
[restic](https://restic.net/) repository: the databases, the search index,
the stored emails and attachments, and the installation: `.env`, the compose
files and what the containers mount from this directory (`env`, `piler.key`,
the license, ...). Other files of this directory are not in it. Only stock
images run it, nothing to install.

`WORKDIR` in `.env` (default `backups/work`) is where the dump and these files
are put together for the backup. It needs room for the dump, which isn't
encrypted there until the backup removes it.

Set `BACKUP_REPOSITORY` in `.env` (setup.sh asks for it):
`s3:https://host/bucket/path` (with `AWS_ACCESS_KEY_ID` and
`AWS_SECRET_ACCESS_KEY`), `sftp:user@host:/path` (with root's SSH key),
`rest:https://host/path`, or a directory: an absolute path outside this
directory, on another disk (a directory on this host's disk is lost with the
host). `BACKUP_PASSWORD` encrypts the backups, setup.sh generates it:
**keep a copy off this host**, without it there's no restore. Then, as
root:

```
../../../scripts/piler-backup.sh install-cron      # every day at 02:30, a file in /etc/cron.d
../../../scripts/piler-backup.sh                   # a backup now
../../../scripts/piler-backup.sh snapshots         # the backups
```

With a directory, create the repository first, with
`BACKUP_INIT=1 ../../../scripts/piler-backup.sh`. Later backups don't create
one: if the disk isn't mounted, they fail instead of filling this host's disk.

Every backup stores only what's new since the last one. The old backups
are removed (7 daily, 4 weekly, 12 monthly, see `BACKUP_KEEP_*`), so purged
emails leave the backups too; on Sundays the space is freed and 5% of the
data is read back to check it. The admin health page shows the last
backup, once piler has the `backup_status` table.

### Restore on a new host

1. Install Docker and get this example (`git clone`); don't run setup.sh.
2. In this directory, create `.env` with `BACKUP_REPOSITORY` and
   `BACKUP_PASSWORD` (and the S3 keys).
3. Pick a backup: `../../../scripts/piler-backup.sh snapshots`
4. `../../../scripts/piler-backup.sh restore <id>`

It restores the files of this directory (the settings, the key, the
license, and the image versions of the backup), the databases, the emails
and the search index, and starts piler. It restores into an installation
without piler's volumes only, it never overwrites an archive. Then point
the hostname to the new host. The emails archived after the backup are not
in it: the mail server keeps sending the queued ones once the host is
back.

`../../../scripts/piler-backup.sh extract <id> <directory>` extracts the
files of a backup without restoring them.

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
   PILER_VERSION=2.3.1
   PILER_SMTP_VERSION=1.1.9
   SCANNER_VERSION=1.3.3
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
