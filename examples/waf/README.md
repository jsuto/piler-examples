# How to add WAF support using traefik

A Web Application Firewall (WAF) improves your security posture.
It may block a wide range of attacks, eg. SQL injection, XSS, etc.

OWASP ModSecurity is a viable solution to implement a WAF. They
provide various docker images that integrates modsecurity to
Apache or Nginx.

In this tutorial we'll create an integration with Traefik.
It supports both middlewares and plugins, and you may use them
to have all incoming requests to be sent to the WAF for inspection.

Docker compose features the following containers:
- traefik: handles incoming requests
- website: an example website we want to protect
- waf: nginx with modsecurity
- dummy: a helper companion for the waf container

The traefik confiugration files defines
- the modsecurity plugin
- the WAF middleware to send the requests for inspection
- the routers and services for each component

## Launch

```
docker compose up
```

## Test

Let's send a valid request

```
curl -H 'Host: website' http://localhost:8000/status
```

The result looks fine:

```
server: 172.25.0.2
time: 31/Mar/2024:07:07:03 +0000
uri: /status
```

Now let's try an XSS attempt:

```
curl -H 'Host: website' "http://localhost:8000/status?waf<script>alert(0)</script>"
```

The result is a HTTP/403 response, the WAF rejected our attempt:

```
<html>
<head><title>403 Forbidden</title></head>
<body>
<center><h1>403 Forbidden</h1></center>
<hr><center>nginx</center>
</body>
</html>
```

You may check the WAF container's log why it blocked the request.
It's a JSON format log. The excerpt is just below.

Feel free to check the formatted JSON output in [waf.log.json](waf.log.json)

```
       "message": "XSS Attack Detected via libinjection",
        "details": {
          "match": "detected XSS using libinjection.",
          "reference": "v10,25t:utf8toUnicode,t:urlDecodeUni,t:htmlEntityDecode,t:jsDecode,t:cssDecode,t:removeNulls",
          "ruleId": "941100",
          "file": "/etc/modsecurity.d/owasp-crs/rules/REQUEST-941-APPLICATION-ATTACK-XSS.conf",
          "lineNumber": "80",
          "data": "Matched Data: XSS data found within ARGS:waf: <script>alert(0)</script>",
          "severity": "2",
          "ver": "OWASP_CRS/4.0.0",
          "rev": "",
          "tags": [
            "modsecurity",
            "application-multi",
            "language-multi",
            "platform-multi",
            "attack-xss",
            "xss-perf-disable",
            "paranoia-level/1",
            "OWASP_CRS",
            "capec/1000/152/242"
          ],
          "maturity": "0",
          "accuracy": "0"
        }
```

## Protecting a webapp not running in a container

In the above example all components were running in docker. But what if your webapp
doesn't run in a container? You may still achieve the same functionality. In this
case run only the WAF and its companion in containers using a trimmed docker-compose.yaml

```
services:
  waf:
    image: owasp/modsecurity-crs:nginx-alpine
    container_name: waf
    environment:
      - PARANOIA=2
      - ANOMALY_INBOUND=10
      - ANOMALY_OUTBOUND=5
      - BACKEND=http://dummy
    ports:
      - "127.0.0.1:8000:8080"
  dummy:
    image: traefik/whoami
    container_name: dummy
```

Then configure traefik (running on the host) to access the WAF at http://127.0.0.1:8000

## Conclusion

We have successfully protected our web app using the ModSecurity WAF.
You may use any containerized or non-containerized application. [Piler enterprise](https://mailpiler.com)
can run both in a container and natively on a host.

## README

[Why does WAF matter in API security?](https://traefik.io/blog/why-does-waf-matter-in-api-security/)

[Traefik proxy with Web Application Firewall (WAF)](https://korteke.medium.com/traefik-proxy-with-web-application-firewall-waf-cb4cd65f34f7)

[Traefik reverse-proxy with ModSecurity](https://blog.xentoo.info/2022/01/22/traefik-reverse-proxy-with-modsecurity/)

[OWASP CRS Docker Image documentation](https://github.com/coreruleset/modsecurity-crs-docker)
