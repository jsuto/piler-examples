# Deploying piler enterprise to docker with docker-compose

## Prerequisites

* Get the license file

## Setup

Customize docker-compose.yaml, and fix the following values:

* MYSQL_PILER_PASSWORD
* MYSQL_ROOT_PASSWORD
* PILER_HOSTNAME
* MULTITENANCY

Check out with-external-volumes.yaml if you don't want docker-compose
to handle the used docker volumes.

Feel free to customize other settings in docker-compose.yaml as well.

## Execute

docker-compose up -d
