# Setup Let's Encrypt certificate with traefik and nginx

## Install traefik edge router

#### Setup the traefik binary

```bash
wget https://github.com/traefik/traefik/releases/download/v2.10.7/traefik_v2.10.7_linux_amd64.tar.gz
tar zxvf traefik_v2.10.7_linux_amd64.tar.gz
cp traefik /usr/local/bin
setcap cap_net_bind_service+ep /usr/local/bin/traefik
```

#### Setup traefik configuration

```
mkdir /usr/local/etc/traefik
cp traefik.yaml /usr/local/etc/traefik
touch /usr/local/etc/traefik/acme.json
chmod 600 /usr/local/etc/traefik/acme.json
chown www-data:www-data /usr/local/etc/traefik/acme.json
```

Be sure to fix your IP-address and domain name in /usr/local/etc/traefik/traefik.yaml!

#### Setup systemd service for traefik

```
cp traefik.service /etc/systemd/system
systemctl daemon-reload
systemctl enable traefik
systemctl start traefik
```

See [https://doc.traefik.io/traefik/getting-started/install-traefik/](https://doc.traefik.io/traefik/getting-started/install-traefik/) for the detailed installation procedure.

## Fix nginx to listen on 127.0.0.1:80

Set the listen address and port to 127.0.0.1:80 in /etc/piler/piler-nginx.conf,
and fix the log format in nginx.conf to get the real IP-addresses, then restart nginx

```
nginx -t
nginx -s reload
```

## Final notes

Traefik obtains you an A-grade https certificate, and automatically renews it before it expires.

The traefik config yaml file uses TLS v1.3. If necessary you may lower the minVersion to your needs.

Optionally visit [https://www.ssllabs.com/ssltest/](https://www.ssllabs.com/ssltest/) to verify it.
