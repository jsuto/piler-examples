## Generate a private key and certificate

```
openssl req -newkey rsa:4096 -new -nodes -x509 -days 3650 -keyout private.key -out public.crt \
   -subj "/C=HU/ST=Budapest/L=Budapest/O=Example/CN=archive.example.com"
```

## Write both private key and certificate to saml2.php

```
python3 -c 'import sys; print("".join(sys.stdin.read().splitlines()))' < private.key
```

Put the output to $settings['sp']['privateKey']

```
python3 -c 'import sys; print("".join(sys.stdin.read().splitlines()))' < public.crt
```

Put the output to $settings['sp']['x509cert']

## Get the SAML2 IdP certificate

Copy the certificate value from https://keycloak.example.com/realms/example-realm/protocol/saml/descriptor
and put it to $settings['idp']['x509cert']
