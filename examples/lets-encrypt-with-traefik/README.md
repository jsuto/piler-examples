# Setup Let's Encrypt certificate with traefik and nginx

## Install traefik edge router

#### Setup the traefik binary

``wget https://github.com/traefik/traefik/releases/download/v2.3.6/traefik_v2.3.6_linux_amd64.tar.gz
tar zxvf traefik_v2.3.6_linux_amd64.tar.gz
cp traefik /usr/local/bin
setcap cap_net_bind_service+ep /usr/local/bin/traefik``

#### Setup traefik configuration

``mkdir /usr/local/etc/traefik
cp traefik.yaml /usr/local/etc/traefik
touch /usr/local/etc/traefik/acme.json
chmod 600 /usr/local/etc/traefik/acme.json
chown www-data:www-data /usr/local/etc/traefik/acme.json``

Be sure to fix your IP-address and domain name in /usr/local/etc/traefik/traefik.yaml!

#### Setup systemd service for traefik

``cp traefik.service /etc/systemd/system
systemctl daemon-reload
systemctl enable traefik
systemctl start traefik``

See [https://doc.traefik.io/traefik/getting-started/install-traefik/]https://doc.traefik.io/traefik/getting-started/install-traefik/) for the detailed installation procedure.

## Fix nginx to listen on 127.0.0.1:80

Set the listen address and port to 127.0.0.1:80 in /etc/piler/piler-nginx.conf
then restart nginx

``nginx -t
nginx -s reload``

