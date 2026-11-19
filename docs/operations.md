# Operations

Day-to-day tasks, and what to do when an alert fires. All commands are run
from the repository root.

## Deploying a new version of the app

The image is built from the git ref in `REDELIVER_REF`.

```bash
# .env
REDELIVER_REF=v0.2.0      # a tag or commit is safer than a moving branch

make up
```

`make up` rebuilds the image and replaces the `app` container. The app gets
20 seconds to finish deliveries that are in flight before it is stopped.
Anything that does not finish in time is sent again after the restart, so a
deploy can cause a duplicate delivery but never a lost one. Webhooks that
arrive during the few seconds the app is down get a `502` or `504` from the
proxy, and senders retry those.

When the ref is a branch, Docker may reuse the source it fetched earlier.
Force a fresh fetch with:

```bash
docker compose build --no-cache app && make up
```

Take a backup first if the new version changes the database schema:
migrations run on startup and are not reversible.

## Rotating the admin token

```bash
rm secrets/admin_token
make init
docker compose up --detach --force-recreate app
```

The token is read once when the container starts, which is why the container
has to be recreated. The same steps work for `secrets/grafana_admin_password`,
with one catch: Grafana only applies the password from the file when its
database is created. For an existing installation, change the password in the
Grafana UI instead.

## Looking at what is going on

```bash
make ps                                  # state and health of every service
make logs                                # follow all logs
docker compose logs --tail 100 app       # one service
docker stats --no-stream                 # CPU and memory against the limits
```

The admin API is the place for questions about individual webhooks:

```bash
TOKEN=$(make token)
curl -s -H "authorization: Bearer $TOKEN" "localhost:8081/api/deliveries?status=dead"
```

## When an alert fires

### RedeliverDown

Prometheus cannot scrape the app.

1. `make ps`. Is `app` running and healthy?
2. `docker compose logs --tail 100 app`. A configuration error is printed
   right before the process exits. A container that restarts in a loop is
   usually that.
3. If the container was killed for using too much memory,
   `docker inspect redeliver-app-1 --format '{{.State.OOMKilled}}'` says so.
   Raise the limit in `compose.yaml`.

While the app is down the proxy answers `502` or `504`. Well-behaved senders retry,
so a short outage normally loses nothing.

### DeadDeliveries

Some deliveries used up all their attempts.

1. List them: `GET /api/deliveries?status=dead`.
2. Look at one: `GET /api/deliveries/<id>` shows every attempt with its
   status code or error.
3. Fix the destination, then `POST /api/deliveries/<id>/retry` for each.

The alert stays active until no delivery is in the `dead` state.

### DeliveryBacklogGrowing

Deliveries are being queued faster than they complete. Almost always one
destination is down or slow.

1. On the dashboard, check *Delivery attempts, by outcome*. Mostly `retry`
   means a destination is failing.
2. `GET /api/deliveries?status=pending` shows which destination the waiting
   deliveries belong to and the last error.
3. If the destination will be down for a while, pause it
   (`PATCH /api/destinations/<id>` with `{"enabled": false}`). Its backlog is
   kept and goes out when it is enabled again.

### MostDeliveryAttemptsFail

Same investigation as above. This one fires earlier, while the queue is
still small.

### SignatureFailures

Many requests with a wrong signature.

- One sender, constant rate: its secret does not match. Recreate the source
  and configure the new secret at the sender.
- Many addresses or random source ids in the proxy log
  (`docker compose logs proxy`): someone is probing. The rate limit already
  slows them down; block the addresses in front of the proxy if needed.

## Backups

`make backup` is safe to run at any time, see the README. Check now and then
that a snapshot can actually be restored: on another machine, or locally with

```bash
RESTORE_YES=1 make restore FILE=backups/<snapshot>.db.gz
make smoke
```

Restoring replaces the whole database. Events received after the snapshot
was taken are gone.

## Where the data is

| Volume | Content | Loss means |
| --- | --- | --- |
| `redeliver_app-data` | SQLite database: sources, secrets, events, deliveries | Everything. This is the one to back up |
| `redeliver_prometheus-data` | Metrics history | Empty graphs, nothing else |
| `redeliver_grafana-data` | Grafana users and settings | Dashboards and the data source come back from the repository |

`make down` keeps all three. `make clean` deletes them.

## Changing limits

| What | Where |
| --- | --- |
| Rate limit and burst | `limit_req_zone` and `limit_req` in `proxy/nginx.conf` |
| Maximum body size | `client_max_body_size` in `proxy/nginx.conf`. The app's own limit (`MAX_BODY_BYTES`) must not be smaller |
| CPU and memory | `deploy.resources.limits` per service in `compose.yaml` |
| Metrics retention | `PROMETHEUS_RETENTION` in `.env` |

After editing `nginx.conf`, check and reload without dropping connections:

```bash
docker compose exec proxy nginx -t
docker compose exec proxy nginx -s reload
```
