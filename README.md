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
| `PROJECT_HOSTNAME` | The `host=` label. Use something recognisable in a dashboard |
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
