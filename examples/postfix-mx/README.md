# Postfix MX Relay for Piler Worker Nodes

Dedicated Postfix MX relay (`ingest.example.com`) that receives emails destined
for `archive.example.com` and distributes them across three piler worker nodes
using DNS-based round-robin.

## Architecture

```
Internet                    Internal network
────────                    ────────────────

                            ┌─── worker0.int.example.com (piler)
                            │
  mail servers ──► ingest.example.com ──┼─── worker1.int.example.com (piler)
   (journal/BCC)        (Postfix MX)    │
                            └─── worker2.int.example.com (piler)
```

Mail servers journal or BCC emails to an address at `archive.example.com`.
The public MX record for that domain points to `ingest.example.com`, which
relays every message to one of the three workers.

## DNS Records

### Public DNS (example.com zone)

```dns
; MX for the archiving domain – points to the relay
archive.example.com.    IN  MX   10  ingest.example.com.

; A/AAAA for the relay itself
ingest.example.com.     IN  A        203.0.113.10
ingest.example.com.     IN  AAAA     2001:db8::10
```

### Internal DNS (int.example.com zone)

The transport map sends mail to `workers.int.example.com`.  Postfix does an MX
lookup and round-robins across equal-priority records.

```dns
; Equal-priority MX records → round-robin load balancing
workers.int.example.com.    IN  MX  10  worker0.int.example.com.
workers.int.example.com.    IN  MX  10  worker1.int.example.com.
workers.int.example.com.    IN  MX  10  worker2.int.example.com.

; A records for each worker
worker0.int.example.com.    IN  A   10.0.1.10
worker1.int.example.com.    IN  A   10.0.1.11
worker2.int.example.com.    IN  A   10.0.1.12
```

## Installation

1. Install Postfix:

   ```bash
   # Debian/Ubuntu
   apt install postfix

   # RHEL/AlmaLinux
   dnf install postfix
   ```

2. Copy configuration files:

   ```bash
   cp main.cf   /etc/postfix/main.cf
   cp master.cf /etc/postfix/master.cf
   cp transport  /etc/postfix/transport
   ```

3. Build the transport hash map:

   ```bash
   postmap /etc/postfix/transport
   ```

4. Set up TLS (use Let's Encrypt or your own CA):

   ```bash
   mkdir -p /etc/postfix/tls
   cp ingest.example.com.crt /etc/postfix/tls/
   cp ingest.example.com.key /etc/postfix/tls/
   chmod 600 /etc/postfix/tls/ingest.example.com.key
   ```

5. Start / reload Postfix:

   ```bash
   systemctl enable --now postfix
   # or, if already running:
   postfix reload
   ```

## How Load Balancing Works

Postfix's built-in MX handling provides the load distribution:

- The `transport` map routes `archive.example.com` to `relay:workers.int.example.com`.
- Postfix resolves the MX records for `workers.int.example.com` and finds three
  entries at equal priority (10).
- For each delivery, Postfix **randomizes** the order of equal-priority MX hosts,
  effectively round-robining across all three workers.
- If a worker is down, Postfix automatically tries the next MX host and queues
  mail for retry if all are unavailable.

## Failover Behavior

| Scenario | Behavior |
|---|---|
| One worker down | Postfix delivers to the remaining two workers |
| Two workers down | All mail goes to the surviving worker |
| All workers down | Mail queued on relay; retried per `queue_run_delay` (60s) for up to `maximal_queue_lifetime` (3 days) |

## Tuning

Key parameters in `main.cf` to adjust based on traffic volume:

| Parameter | Default | Purpose |
|---|---|---|
| `relay_destination_concurrency_limit` | 20 | Max parallel connections per worker |
| `relay_destination_recipient_limit` | 50 | Max recipients per delivery |
| `smtpd_client_message_rate_limit` | 200 | Inbound rate limit per source IP |
| `maximal_queue_lifetime` | 3d | How long to retry failed deliveries |

## Monitoring

```bash
# Queue status
postqueue -p

# Mail log (Debian/Ubuntu)
tail -f /var/log/mail.log

# Mail log (RHEL/AlmaLinux)
journalctl -fu postfix

# Connection stats
postfix check
```

## Security Notes

- The relay only accepts mail for `archive.example.com` (`relay_domains`).
  All other destinations are rejected (`reject_unauth_destination`).
- No local delivery is configured (`mydestination` is empty).
- TLS is opportunistic inbound; disable or enable outbound TLS to workers
  as appropriate for your network.
- Consider adding firewall rules to restrict SMTP (port 25) to known source
  mail server IPs if your environment allows it.

## Files

| File | Description |
|---|---|
| `main.cf` | Main Postfix configuration |
| `master.cf` | Postfix service definitions |
| `transport` | Transport map routing archive.example.com to worker pool |
