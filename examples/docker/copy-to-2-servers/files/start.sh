#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

cp /etc/resolv.conf /var/spool/postfix/etc/
rsyslogd
postfix start
sleep infinity
