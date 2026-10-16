#!/usr/bin/env bash
# telemetry.sh — local OTel stack: backends on Mac + collector on the workload kind cluster.
#
# Usage:
#   ./telemetry.sh up        # start backends (Docker) + install collector + metric CRs
#   ./telemetry.sh down      # remove collector + metric CRs + stop backends
#   ./telemetry.sh status    # is anything up?
#   ./telemetry.sh reset     # docker compose down -v (wipes all metric/log data) + fresh up
#
# Run AFTER: task test-e2e -- --keep-clusters   (kept-cluster kubeconfig is auto-discovered)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Our own namespace, distinct from the e2e ProviderConfig releases in odg-system.
NS=telemetry-local
OBSERVED_NS=odg-system

need() { command -v "$1" >/dev/null || { echo "ERROR: $1 not found in PATH"; exit 1; }; }
need docker; need helm; need kubectl; need curl

say() { echo "▸ $*"; }

# ─── locate the kind workload cluster ────────────────────────────────────────
find_kubeconfig() {
  local name
  name=$(kind get clusters 2>/dev/null | grep '^workload-odg' | head -1 || true)
  [ -n "$name" ] || { echo "ERROR: no kind cluster named workload-odg* — run: task test-e2e -- --keep-clusters"; exit 1; }
  kind get kubeconfig --name "$name" > /tmp/odg-telemetry-wl.kubeconfig || exit 1
  KUBECONFIG_FILE=/tmp/odg-telemetry-wl.kubeconfig
  if ! kubectl --kubeconfig="$KUBECONFIG_FILE" get nodes >/dev/null 2>&1; then
    echo "ERROR: found cluster '$name' but it's not reachable. Still running? Then re-run task test-e2e."; exit 1
  fi
  say "workload cluster: $name"
}
K() { kubectl --kubeconfig="$KUBECONFIG_FILE" "$@"; }

cmd_up() {
  say "1/4  backends (Docker)"
  docker compose -f "$HERE/compose.yml" up -d

  say "2/4  waiting for opensearch (:9200) + prometheus (:9090)"
  local ok=0
  for _ in $(seq 1 60); do
    curl -s -o /dev/null localhost:9200 \
      && curl -s -o /dev/null localhost:9090/-/ready \
      && { ok=1; break; }
    sleep 2
  done
  [ $ok -eq 1 ] || { echo "ERROR: backends not ready after 2m. docker compose -f $HERE/compose.yml logs"; exit 1; }

  find_kubeconfig

  say "3/4  helm install metrics-operator + collector  namespace=$NS"
  K create namespace "$NS" --dry-run=client -o yaml | K apply -f -
  helm upgrade --install metrics-operator-local \
    oci://ghcr.io/openmcp-project/charts/metrics-operator --version v1.2.0 \
    --set fullnameOverride=metrics-operator-local \
    -n "$NS" --kubeconfig="$KUBECONFIG_FILE" --wait --timeout 3m || exit 1
  helm upgrade --install otel-collector-local \
    oci://ghcr.io/open-telemetry/opentelemetry-helm-charts/opentelemetry-collector --version 0.139.0 \
    -f "$HERE/collector-values.yaml" -n "$NS" --kubeconfig="$KUBECONFIG_FILE" --wait --timeout 5m || exit 1

  say "4/4  apply DataSink + Metric CRs"
  K apply -f "$HERE/metrics-operator-cr.yaml" || exit 1

  say "opening port-forward :8889 -> collector :8889 (for Prometheus scrape)"
  lsof -ti tcp:8889 | xargs kill -9 2>/dev/null || true
  pkill -f 'port-forward pod/.*8889:8889' 2>/dev/null || true
  # the collector daemonset pod must be Ready before pf binds, else pf exits immediately
  K rollout status ds/otel-collector-local-agent -n "$NS" --timeout=120s || { echo "ERROR: collector not ready"; exit 1; }
  # port-forward the POD (8889 isn't on the Service). Restart loop: pf dies on conn reset.
  local pod
  pod=$(K get pod -n "$NS" -l app.kubernetes.io/name=opentelemetry-collector -o jsonpath='{.items[0].metadata.name}')
  nohup bash -c 'while true; do
    kubectl --kubeconfig="'"$KUBECONFIG_FILE"'" -n '"$NS"' port-forward pod/'"$pod"' 8889:8889 >>/tmp/pf-otel-metrics.log 2>&1
    sleep 1
  done' >/dev/null 2>&1 &
  disown
  sleep 3
  lsof -i tcp:8889 >/dev/null 2>&1 || { echo "ERROR: port-forward failed to bind :8889 — see /tmp/pf-otel-metrics.log"; exit 1; }

  echo
  cat <<'EOF'

  UP ✓   (no logins anywhere — security plugins disabled)

  METRICS — http://localhost:9090
    Graph tab, type:
      odg_pods_running                      # ~21 odg-system pods, value 1 each
      system_cpu_utilization_ratio          # host metrics
    Status -> Targets: 'otel-collector' should be UP
    filter labels: pod, resource_namespace, deployment

  LOGS — http://localhost:5601   (OpenSearch Dashboards, no password)
    one-time setup:  menu -> Management -> Dashboards Management -> Index patterns
                     -> Create -> name 'logs-otel-v1' -> time field '@timestamp'
    then menu -> Discover, pick 'logs-otel-v1'. Filters:
      resource.k8s.deployment.name: "delivery-service"
      resource.k8s.pod.name: "otel-collector-*"
      body: "ERROR"

  RAW / debug (no UI):
      curl -s localhost:9200/logs-otel-v1/_count
      curl -s 'localhost:9090/api/v1/query?query=odg_pods_running'
      ./telemetry.sh status

  NOTE: filelog scope = odg-system namespace -> all odg-system pod logs flow
        (annotation gate removed). Raw API localhost:9200, index logs-otel-v1.
EOF
}

cmd_down() {
  say "removing collector + metric CRs"
  if name="$(kind get clusters 2>/dev/null | grep '^workload-odg' | head -1)"; then
    kind get kubeconfig --name "$name" > /tmp/odg-telemetry-wl.kubeconfig 2>/dev/null || true
    KUBECONFIG_FILE=/tmp/odg-telemetry-wl.kubeconfig
    K delete -f "$HERE/metrics-operator-cr.yaml" --ignore-not-found
    helm uninstall otel-collector-local metrics-operator-local -n "$NS" --kubeconfig="$KUBECONFIG_FILE" 2>/dev/null || true
    pkill -f 'port-forward pod/.*8889:8889' 2>/dev/null || true
  else
    say "no workload cluster found — skipping cluster teardown"
  fi
  say "stopping backends"
  docker compose -f "$HERE/compose.yml" down
  echo "  DOWN ✓  (data kept — use ./telemetry.sh reset to wipe)"
}

cmd_status() {
  say "port-forward (:8889 collector metrics):"
  lsof -i tcp:8889 >/dev/null 2>&1 && echo "  up" || echo "  down"
  echo
  say "backends (Docker):"
  docker compose -f "$HERE/compose.yml" ps --format 'table {{.Name}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null \
    | grep -E 'odg-telemetry|NAMES' || echo "  (not running)"
  echo
  say "endpoints:"
  curl -s -o /dev/null -w '  prometheus  %{http_code}\n' localhost:9090/-/ready || echo "  prometheus  down"
  curl -s -o /dev/null -w '  opensearch  %{http_code}\n' localhost:9200        || echo "  opensearch  down"
  curl -s -o /dev/null -w '  dashboards  %{http_code}\n' localhost:5601/api/status || echo "  dashboards  down"
  echo
  if name="$(kind get clusters 2>/dev/null | grep '^workload-odg' | head -1)"; then
    say "cluster pods ($name):"
    kind get kubeconfig --name "$name" > /tmp/odg-telemetry-wl.kubeconfig 2>/dev/null
    kubectl --kubeconfig=/tmp/odg-telemetry-wl.kubeconfig get pods -n "$NS" --no-headers 2>/dev/null \
      | grep -E 'otel|metrics-operator' || echo "  (not installed)"
  fi
}

cmd_reset() {
  say "wiping all telemetry data"
  docker compose -f "$HERE/compose.yml" down -v
  cmd_up
}

case "${1:-}" in
  up)     cmd_up ;;
  down)   cmd_down ;;
  status) cmd_status ;;
  reset)  cmd_reset ;;
  *) echo "usage: $0 {up|down|status|reset}"; exit 1 ;;
esac
