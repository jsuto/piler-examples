## Send email to 2 tenants

```
smtp-source.py -s 127.0.0.1 -p 3535 --eml somespam.eml -r qqq@archive.piler
smtp-source.py -s 127.0.0.1 -p 3535 --eml somespam.eml -r zzz@archive.piler
```

## Logs on the smtp gateway

```
root@smtpgw:/# tail -f /var/log/mail.log
2025-07-30T18:14:28.113997+00:00 smtpgw postfix/postfix-script[95]: starting the Postfix mail system
2025-07-30T18:14:28.133627+00:00 smtpgw postfix/master[98]: daemon started -- version 3.8.6, configuration /etc/postfix
2025-07-30T18:15:00.618493+00:00 smtpgw postfix/smtpd[110]: connect from unknown[172.22.0.1]
2025-07-30T18:15:00.651668+00:00 smtpgw postfix/smtpd[110]: 9F0AECACEE: client=unknown[172.22.0.1]
2025-07-30T18:15:00.668631+00:00 smtpgw postfix/cleanup[115]: 9F0AECACEE: message-id=<037d01d1935a$ef85ad30$cdbf1d6e@ebbawdj>
2025-07-30T18:15:00.676428+00:00 smtpgw postfix/smtpd[110]: disconnect from unknown[172.22.0.1] ehlo=1 mail=1 rcpt=1 data=1 quit=1 commands=5
2025-07-30T18:15:00.680211+00:00 smtpgw postfix/qmgr[100]: 9F0AECACEE: from=<sender@example.com>, size=176682, nrcpt=2 (queue active)
2025-07-30T18:15:00.714331+00:00 smtpgw postfix/smtp[116]: 9F0AECACEE: to=<qqq@worker101>, orig_to=<qqq@archive.piler>, relay=worker101[172.22.0.2]:25, delay=0.07, delays=0.04/0.02/0.01/0.01, dsn=2.0.0, status=sent (250 2.0.0 Ok)
2025-07-30T18:15:00.723181+00:00 smtpgw postfix/smtp[116]: 9F0AECACEE: to=<qqq@worker201>, orig_to=<qqq@archive.piler>, relay=worker201[172.22.0.3]:25, delay=0.08, delays=0.04/0.04/0/0.01, dsn=2.0.0, status=sent (250 2.0.0 Ok)
2025-07-30T18:15:00.723461+00:00 smtpgw postfix/qmgr[100]: 9F0AECACEE: removed
2025-07-30T18:15:14.836604+00:00 smtpgw postfix/smtpd[110]: connect from unknown[172.22.0.1]
2025-07-30T18:15:14.841358+00:00 smtpgw postfix/smtpd[110]: CD5A5CACEE: client=unknown[172.22.0.1]
2025-07-30T18:15:14.857709+00:00 smtpgw postfix/cleanup[115]: CD5A5CACEE: message-id=<037d01d1935a$ef85ad30$cdbf1d6e@ebbawdj>
2025-07-30T18:15:14.865684+00:00 smtpgw postfix/qmgr[100]: CD5A5CACEE: from=<sender@example.com>, size=176682, nrcpt=2 (queue active)
2025-07-30T18:15:14.866224+00:00 smtpgw postfix/smtpd[110]: disconnect from unknown[172.22.0.1] ehlo=1 mail=1 rcpt=1 data=1 quit=1 commands=5
2025-07-30T18:15:14.883891+00:00 smtpgw postfix/smtp[116]: CD5A5CACEE: to=<zzz@worker201>, orig_to=<zzz@archive.piler>, relay=worker201[172.22.0.3]:25, delay=0.04, delays=0.03/0.01/0/0.01, dsn=2.0.0, status=sent (250 2.0.0 Ok)
2025-07-30T18:15:14.884378+00:00 smtpgw postfix/smtp[117]: CD5A5CACEE: to=<zzz@worker101>, orig_to=<zzz@archive.piler>, relay=worker101[172.22.0.2]:25, delay=0.05, delays=0.03/0/0.01/0.01, dsn=2.0.0, status=sent (250 2.0.0 Ok)
2025-07-30T18:15:14.884726+00:00 smtpgw postfix/qmgr[100]: CD5A5CACEE: removed
```
