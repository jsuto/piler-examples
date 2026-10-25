# Deploying piler enterprise containers on multiple nodes

## The layout

This setup features the following hosts:
* master.example.com
* worker0.example.com

Containers on the master node:
- piler
- manticore
- mysql
- memcached

Containers on the worker node:
- piler
- manticore
- mysql
- memcached
- tika

## Deployment

Install the mysql encryption stuff and docker on both master and worker nodes

```
./install.sh
```

Copy 11-piler.conf to both nodes to enable centralised logging. Be sure to fix the target hostname.

## Setup the master node

Copy master dir contents to the master node.

```
scp master/* master.example.com:~
```

Customize docker-compose.yaml, and be sure to update
- PILER_HOSTNAME
- WORKERS
- MANTICORE_WORKERS
- AUTH_CODE
- mysql passwords

Create the required docker volumes:

```
docker volume create piler_db
docker volume create piler_manticore
docker volume create piler_etc
```

Run the containers

```
docker compose up -d
```

## Setup the worker node (worker0)

Copy worker0 dir contents to the worker node.

```
scp worker0/* worker0.example.com:~
```

Create the required docker volumes:

```
docker volume create piler_db
docker volume create piler_manticore
docker volume create piler_etc
docker volume create piler_store
docker volume create piler_astore
```

Customize docker-compose.yaml, and be sure to update
- PILER_HOSTNAME
- MASTER_NODE
- AUTH_CODE
- mysql passwords

Note that "AUTH_CODE" must be the same on both the master and the worker nodes.

Customize piler.conf.worker0 as well, set the passwords, crypt_key, etc.

Get the license files for worker0.example.com, and save it as worker0.example.com.lic

Run the containers

```
docker compose up -d
```

## Exposed ports on the nodes

Master node:
- 80/tcp
- 3306/tcp

Worker node:
- 25/tcp
- 80/tcp
- 9312/tcp

## Further improvements

Use https protocol on the nodes. You may update /etc/piler/piler-nginx.conf
with the tls setup, and put the certificate(s) and key on the piler_etc volume.

Or another option might be running traefik on the nodes and terminate https connections.

Enable https between the master and worker node. To do that edit /etc/piler/config-site.php,
and set the API_PROTO variable to use https:

```
$config['API_PROTO'] = 'https://';
```

Enable tls in transit for mysql

You may increase the memory limits set in the docker-compose.yaml files to match your workload.
