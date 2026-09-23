# observability-shipper

Ships a host's container logs and host/container metrics to a central
Grafana Alloy → Loki / Prometheus stack.

One of these per host. The application can be anything — Node, Laravel,
WordPress, hand-rolled — because it reads container logs off the Docker API
and host stats off `/proc`, which are the same everywhere.

```
compose.yaml   alloy + docker-socket-proxy + cadvisor
config.alloy                copy unchanged
.env.template               copy to .env and fill in
install.sh                  fetches the three above
```

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/OWNER/observability-shipper/main/install.sh \
  | sudo bash -s -- my-project
```

Then set the two endpoints in `/opt/observability/.env` and:

```bash
cd /opt/observability && docker compose up -d
```

Re-running the installer updates the three tracked files and leaves `.env`
alone, so upgrading a fleet is the same one-liner.

## Configure

Everything host-specific is in `.env`. `config.alloy` is copied unchanged and
should stay that way — if a host needs different behaviour, that is a signal
the difference belongs in a label, not in a forked config.

| Variable | Notes |
| --- | --- |
| `PROJECT_NAME` | The `project=` label on every line and series |
| `CONTAINER_PREFIX` | Only `<prefix>`, `<prefix>-*` and `system-*` containers are collected. A regex: pipe-separated, `.*` for everything |
| `PROJECT_ENVIRONMENT` | `production`, `staging`, … |
| `PROJECT_HOSTNAME` | The `host=` label. **Unique per box** — boxes sharing a `PROJECT_NAME` are told apart by this alone, and duplicating it makes metrics silently lossy |
| `LOKI_ENDPOINT` | `…/loki/api/v1/push` |
| `METRICS_ENDPOINT` | `…/api/v1/write` |
| `INGEST_USERNAME` / `INGEST_PASSWORD` | Leave **both** blank on a private path |

**The endpoints have no defaults on purpose.** A plausible-looking default is
how a host ends up shipping to the wrong aggregator, and that failure is
silent — logs arrive somewhere, just not where anyone is looking.

### Private path or published path

Over a private network — same VPC, or peered — ship plain HTTP to an internal
name and leave the credentials blank. The network is the authorisation:

```
LOKI_ENDPOINT=http://logs.internal.example:8100/loki/api/v1/push
METRICS_ENDPOINT=http://logs.internal.example:8100/api/v1/write
```

From anywhere else, use the published ingest host over HTTPS with a
per-host credential, so a compromised host is revoked on its own:

```
LOKI_ENDPOINT=https://logs.example.com/loki/api/v1/push
METRICS_ENDPOINT=https://logs.example.com/api/v1/write
INGEST_USERNAME=my-project
INGEST_PASSWORD=…
```

## Verify

```bash
docker compose ps
docker logs --tail 20 system-alloy
curl -sS http://127.0.0.1:12345/-/ready
```

Then in Grafana: `{project="my-project"}` for logs, `up{project="my-project"}`
for metrics. **Confirm on one host before installing on a second** — the
common failures (wrong endpoint, unreachable name, blocked port) look
identical from the shipper's side, and finding them once is much cheaper than
finding them twenty times.

## Notes

`CONTAINER_PREFIX` decides what is collected. The filter is applied twice —
once for logs, once for cAdvisor — because cAdvisor reports every container
on the host regardless of the log discovery filter.

The value is interpolated into a regex, not a list, so several projects on one
box are separated by a pipe:

```
CONTAINER_PREFIX=shop|checkout
```

A bare `*` is not a wildcard — it is an invalid regex and Alloy will refuse to
start. To collect every container on the host, including names with no hyphen:

```
CONTAINER_PREFIX=.*
```

Worth a moment's thought before you do. That same filter is the only thing
limiting what cAdvisor ships, its per-container, per-interface and
per-filesystem series are comfortably the highest-cardinality thing here, and
a Prometheus remote-write receiver has no `limits_config` equivalent to reject
what it is sent — the failure mode is head growth on the aggregator, not a 429
on this box.

### nginx per-site logs

Two filename conventions are read without configuration:

```
example.com-access.log      ->  site="example.com"
access-example.com.log      ->  site="example.com"
```

Rotated files are excluded on purpose — every glob ends in `.log`, so
`access.log.1` and `access.log.9.gz` match nothing. logrotate renames files
into positions already read, so including them would re-ingest months of
history on every restart and again each midnight. Use `NGINX_BACKFILL_DIR`
for history you actually want.

The site label is simply whatever is left after stripping the `access`/`error`
part. A filename carrying a box or environment prefix puts that prefix in the
label:

```
error-boxname-shop.log      ->  site="boxname-shop"
```

That groups fine, but it is no longer a domain, so anything matching sites to
domains will not line up. Name the files after the domain if that matters.
`NGINX_SITE_REGEX` overrides the extraction for a box that does something else
entirely.

A single combined `access.log` cannot produce per-site labels at all — the
label comes from the filename, so nginx needs a per-vhost `access_log`
directive for any of this to work.

### The `bot` label

Access lines are classified as automated or not **as they are read**, and ship
with a `bot="true"/"false"` stream label. Dashboards then filter with
`{bot!="true"}` — a stream selector, so Loki skips the chunks entirely.

This replaced a 50-branch regex over the user agent at query time. That regex
ran against every parsed line on every panel load, and once sites had a
fortnight of history behind them, 14-day views simply timed out on it.

Two things follow from it being a stream label:

- **It doubles the stream count** for nginx access logs, which is the price.
  Two values per site, well inside `max_streams_per_user`.
- **Lines ingested before this existed carry no label at all.** Loki reads an
  absent label as empty, so `bot!="true"` still finds them and human figures
  stay correct, while `bot="true"` only sees lines classified since — so
  automated figures under-report for older data until it ages out of
  retention. Re-ingest if that matters: delete the old stream through Loki's
  delete API and run the backfill again.

The agent is taken as the last of the two adjacent quoted fields, which holds
for stock combined and for the extended format with `rt=`/`urt=`/`host=` after
it, because referer and agent stay adjacent in both.

### Our own uptime monitor

Uptime Kuma's checks are dropped before they ship: a line is discarded when it
comes from an address in `MONITOR_IPS` (set in `.env`; unset drops nothing) **and** carries the
`Uptime-Kuma/` agent. Both, so a scanner borrowing the agent string is still
logged. Any other uptime checker (Uptime Kuma elsewhere, Pingdom, StatusCake,
anything naming itself a monitor) is kept but classified `bot="true"`.

Lines already in Loki are not touched -- the monitor's history ages out with
retention, or delete it through Loki's delete API.

### Backfilling history

Three gates stop old lines, and all three have to open. Two are on the box,
one is on the aggregator.

1. **The aggregator's Loki** refuses anything past its
   `reject_old_samples_max_age`. Nothing you do on a shipper changes this, and
   it fails per line with no summary, so check it first.
2. **`LOG_MAX_AGE`** — Alloy drops older lines before shipping. Default 168h.
3. **The live globs match only `*.log`**, never `.log.1` or `.log.9.gz`. Your
   history is in rotated files nothing reads, by design: logrotate renames
   files into positions already read, so widening the globs would re-ingest
   months on every restart and again each midnight.

So backfill is a separate directory you fill on purpose:

```
mkdir -p /var/log/nginx-backfill

# keep the filename identical to the live one, minus the rotation suffix --
# the site label comes from the filename, and a different name means a
# different site
zcat /var/log/nginx/access-example.log.*.gz \
  | cat - /var/log/nginx/access-example.log.1 \
  > /var/log/nginx-backfill/access-example.log
chown www-data:adm /var/log/nginx-backfill/*.log
chmod 640 /var/log/nginx-backfill/*.log
```

Then in `.env`:

```
LOG_MAX_AGE=744h
NGINX_BACKFILL_DIR=/var/log/nginx-backfill
```

and `docker compose up -d` — **not `restart`**, which reuses the container and
its old environment, and would not pick up the new bind mount either.

Confirm Alloy can actually see the files before waiting on data:

```
docker exec system-alloy ls -l /var/log/nginx-backfill/
```

An empty listing means the mount is not there, which looks identical to a
backfill that shipped nothing.

Watch it drain with `docker compose logs -f alloy`, confirm the data is there,
then unset both and `up -d` again.

To re-ingest a backfill that arrived before the `bot` label existed, delete
the old copy on the aggregator (`./scripts/delete-backfill.sh`) and run
`./reingest-backfill.sh` here. Alloy remembers how far it read into every
file, so a plain restart re-ships nothing; that script clears the position for
the backfill component alone, leaving every live log's position intact.

Three things worth knowing:

- Lines ship with `backfill="true"`, which puts them in their own stream.
  That is load-bearing: Loki accepts out-of-order writes only within a window
  relative to a stream's head, so old lines pushed into a stream holding
  today's are refused as *too far behind*. `{service="nginx-access"}` still
  matches them, so every dashboard sees the history with no query change.
- **Alloy remembers what it has read.** Positions live in its data volume, so
  re-running the same file ships nothing twice — and equally, fixing a mistake
  means a new filename, not a re-run.
- Ingesting further back than the aggregator's `retention_period` is wasted
  work. It lands and the compactor deletes it.

`cadvisor` runs privileged; it needs cgroup and Docker filesystem access,
which is why it is a separate container rather than folded into Alloy. Drop
the service and the `prometheus.scrape "cadvisor"` block if that is not
acceptable on a given host — host metrics and logs are unaffected.

Alloy's debug UI binds to `127.0.0.1`. No inbound port is opened on the host.

Containers, network and volume are named `system-*` rather than per-project:
there is only ever one of these on a host, and fixed names mean the compose
file is identical everywhere.

## Labels

Required on every stream: `project`, `environment`, `host`, plus `service`,
`container` and `level` which come off the Docker API and the log line.

High-cardinality labels are banned — request ID, user ID, IP address, full
URL with query string, session ID. Put those in the log body.
