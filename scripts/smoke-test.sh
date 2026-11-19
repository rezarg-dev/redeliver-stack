#!/usr/bin/env bash
# Checks a running stack from the outside: what must be reachable is
# reachable, what must not be exposed is not, and a webhook makes it through
# the proxy into the app.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

public="http://127.0.0.1:${PUBLIC_PORT:-8080}"
admin="http://127.0.0.1:${ADMIN_PORT:-8081}"
prometheus="http://127.0.0.1:${PROMETHEUS_PORT:-9090}"
grafana="http://127.0.0.1:${GRAFANA_PORT:-3001}"
token="$(cat secrets/admin_token)"

failures=0

# expect <description> <expected status> <curl arguments...>
expect() {
  local description="$1" expected="$2" actual
  shift 2
  actual="$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 10 "$@" || true)"
  if [[ "$actual" == "$expected" ]]; then
    echo "ok    $description"
  else
    echo "FAIL  $description (expected $expected, got $actual)"
    failures=$((failures + 1))
  fi
}

echo "public listener"
expect "unknown paths are a 404" 404 "$public/"
expect "admin API is not exposed" 404 "$public/api/sources"
expect "metrics are not exposed" 404 "$public/metrics"
expect "health check is not exposed" 404 "$public/healthz"
expect "unknown source is a 404 from the app" 404 --request POST --data '{}' "$public/in/src_missing"

echo "admin listener"
expect "health check passes" 200 "$admin/healthz"
expect "metrics are not exposed" 404 "$admin/metrics"
expect "API rejects a missing token" 401 "$admin/api/sources"
expect "API accepts the admin token" 200 --header "authorization: Bearer $token" "$admin/api/sources"

echo "webhook round trip"
name="smoke-test-$(date +%s)"
created="$(curl --silent --max-time 10 --request POST "$admin/api/sources" \
  --header "authorization: Bearer $token" --header 'content-type: application/json' \
  --data "{\"name\":\"$name\",\"scheme\":\"none\"}")"
source_id="$(printf '%s' "$created" | sed -n 's/.*"id":"\(src_[^"]*\)".*/\1/p')"

if [[ -z "$source_id" ]]; then
  echo "FAIL  could not create a source: $created"
  failures=$((failures + 1))
else
  expect "webhook is accepted through the proxy" 202 --request POST \
    --header 'content-type: application/json' --data '{"smoke":"test"}' "$public/in/$source_id"
  oversized="$(mktemp)"
  head -c 300000 /dev/zero > "$oversized"
  expect "oversized webhook is rejected by the proxy" 413 --request POST \
    --data-binary "@$oversized" "$public/in/$source_id"
  rm -f "$oversized"
  expect "test source is removed again" 204 --request DELETE \
    --header "authorization: Bearer $token" "$admin/api/sources/$source_id"
fi

echo "monitoring"
expect "Prometheus is healthy" 200 "$prometheus/-/healthy"
expect "Grafana is healthy" 200 "$grafana/api/health"

# Prometheus needs up to one scrape interval before the target shows up.
target_up=""
for _ in $(seq 1 20); do
  target_up="$(curl --silent --max-time 5 --get "$prometheus/api/v1/query" \
    --data-urlencode 'query=up{job="redeliver"}' | sed -n 's/.*"value":\[[^,]*,"\([^"]*\)"\].*/\1/p' || true)"
  [[ "$target_up" == "1" ]] && break
  sleep 2
done
if [[ "$target_up" == "1" ]]; then
  echo "ok    Prometheus scrapes the app"
else
  echo "FAIL  Prometheus does not scrape the app (up=${target_up:-no data})"
  failures=$((failures + 1))
fi

echo
if ((failures > 0)); then
  echo "$failures check(s) failed"
  exit 1
fi
echo "all checks passed"
