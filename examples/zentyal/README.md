# Deploying piler to Zentyal using docker-compose

## The goal

We are going to install piler in a dockerized environment.
The GUI will authenticate users using the LDAP server (ie.
Samba) running on Zentyal. Postfix will send a copy of each
received email to the archive.

## The layout

This setup features the following containers:

* mariadb: storing metadata, user db, etc.
* memcached: to cache some data
* Piler 1.3.10: the email archive running piler and sphinxsearch

Port mappings to containers:

- piler: 8080/tcp, 2525/tcp

No other port should be visible from the outside.

## Prerequisites

* You have a Zentyal deployment with mail support

## Install docker components

```
apt-get install -y docker-compose docker.io
```

## Setup

### Customize docker-compose.yaml

Fix the following values:

* MYSQL_PILER_PASSWORD
* PILER_HOSTNAME


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
  piler_var:
    external: true
    name: piler-var
```


## Start the containers

```
docker-compose up -d
```


### Create a transport map for piler

```
echo "archive.yourdomain.com:   smtp:[127.0.0.1]:2525" > /etc/postfix/transport.piler
```

## Create piler related changes to the system

```
cp /usr/share/zentyal/stubs/mail/main.cf.mas .
patch < main.cf.mas.diff
mkdir -p /etc/zentyal/stubs/mail
cp main.cf.mas /etc/zentyal/stubs/mail
cp mail.postsetconf /etc/zentyal/hooks
chmod +x /etc/zentyal/hooks/mail.postsetconf
```

### Configure Bcc for your domains

Select "Mail" menu, then "Virtual Mail Domains" on the Zentyal dashboard.
Click on the "Settings" gear icons for the domain you want to archive emails.

Select "Address to sent the copy" from the dropdown menu, and type
"archive@archive.yourdomain.com", then click "Change", and "Save changes".

## Fix the piler GUI config

Read /etc/postfix/valiases.cf to get the LDAP bind user parameters, then
add the following settings to /var/lib/docker/volumes/u1_piler_etc/_data/config-site.php:
(Your volume path might be different!)

```
$config['ENABLE_LDAP_AUTH'] = 1;
$config['LDAP_HOST'] = 'ldap://zentyal.yourdomain.com:389';
$config['LDAP_HELPER_DN'] = 'CN=zentyal-mail-zentyal,CN=Users,DC=zentyal-domain,DC=lan';
$config['LDAP_HELPER_PASSWORD'] = 'xxxxx';
$config['LDAP_BASE_DN'] = 'DC=zentyal-domain,DC=lan';
$config['LDAP_ACCOUNT_OBJECTCLASS'] = 'user';
$config['LDAP_DISTRIBUTIONLIST_OBJECTCLASS'] = 'group';
$config['LDAP_DISTRIBUTIONLIST_ATTR'] = 'member';
$config['LDAP_MAIL_ATTR'] = 'mail';
```

Also and add ":8080" (without quotes) to the SITE_URL parameter, eg.

```
$config['SITE_URL'] = 'http://' . $config[SITE_NAME_CONST] . ':8080/';
```


## Add a firewall rule to allow users login to the GUI

Select "Firewall" menu, then "Packet filter", and "Filtering rules from internal networks to Zentyal".
Click on "Configure rules", and add a service and a rule to allow incoming requests to port 8080.

## Final words

You just got a piler deployment in a containerized environment on Zentyal.
