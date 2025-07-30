## docker buildx build -t smtpgw:latest --load .
FROM ubuntu:24.04

LABEL description="piler smtp gateway container"
LABEL maintainer="Janos SUTO, sj@acts.hu"

ENV DEBIAN_FRONTEND="noninteractive"

COPY files /tmp

# hadolint ignore=DL3008
RUN apt-get update && \
    apt-get -y --no-install-recommends install postfix postfix-pcre rsyslog && \
    apt-get clean && rm -rf /var/lib/apt/lists/* && \
    mv /tmp/start.sh /start.sh && \
    mv /tmp/domains /etc/postfix && \
    postmap /etc/postfix/domains && \
    mv /tmp/virtual /etc/postfix && \
    mv /tmp/main.cf /etc/postfix

EXPOSE 25

CMD ["/start.sh"]
