#!/usr/bin/env bash
# telemetry.sh — local OTel stack for e2e-kept clusters: backends on Mac (docker)
# + the odg-observability telemetry chart (collector + metrics-operator + Metric CRs)
# installed straight onto the workload kind cluster.
#
# Usage:
#   ./telemetry.sh up        # backends + helm install + port-forward
#   ./telemetry.sh down      # helm uninstall + stop backends (data kept)
#   ./telemetry.sh status    # is anything up?
#   ./telemetry.sh reset     # wipe all data (compose down -v) + fresh up
#
# Run AFTER: task test-e2e -- --keep-clusters   (kubeconfig is auto-discovered)
#
# Unlike the open-delivery-gear variant this targets the *workload-odg* kind cluster
# that e2e leaves behind, and it needs NO platform-cluster patching: the umbrella
# chart carries DataSink + Metric CRs + NetworkPolicies itself.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ODG_OBSERVABILITY="${ODG_OBSERVABILITY:-$HERE/../../odg-observability}"
CHART="$ODG_OBSERVABILITY/charts/telemetry"
OBSERVED_NS=odg-system            # where odg components live on the workload cluster
RELEASE=telemetry

need() { command -v "$1" >/dev/null || { echo "ERROR: $1 not found in PATH"; exit 1; }; }
need docker; need helm; need kubectl; need curl

say() { echo "▸ $*"; }

find_kubeconfig() {
  local wl
  wl=$(kind get clusters 2>/dev/null | grep '^workload-odg' | head -1 || true)
  [ -n "$wl" ] || { echo "ERROR: no kind cluster named workload-odg* — run: task test-e2e -- --keep-clusters"; exit 1; }
  kind get kubeconfig --name "$wl" > /tmp/odg-telemetry-wl.kubeconfig || exit 1
  KUBECONFIG_FILE=/tmp/odg-telemetry-wl.kubeconfig
  kubectl --kubeconfig="$KUBECONFIG_FILE" get nodes >/dev/null 2>&1 \
    || { echo "ERROR: workload cluster '$wl' not reachable. Still running? Then re-run task test-e2e."; exit 1; }
  say "workload cluster: $wl"
}
K() { kubectl --kubeconfig="$KUBECONFIG_FILE" "$@"; }

cmd_up() {
  [ -d "$CHART" ] || { echo "ERROR: telemetry chart not found at $CHART — checkout odg-observability beside this repo"; exit 1; }

  say "1/4  backends (Docker)"
  docker compose -f "$HERE/compose.yml" up -d

  say "2/4  waiting for opensearch (:9200) + prometheus (:9090) + dashboards data view"
  local ok=0
  for _ in $(seq 1 60); do
    curl -s -o /dev/null localhost:9200 \
      && curl -s -o /dev/null localhost:9090/-/ready \
      && { ok=1; break; }
    sleep 2
  done
  [ $ok -eq 1 ] || { echo "ERROR: backends not ready after 2m. docker compose -f $HERE/compose.yml logs"; exit 1; }

  # data view so Discover works out of the box (2xx = ok)
  ok=0
  for _ in $(seq 1 90); do
    if curl -s -o /dev/null -w '%{http_code}' \
      -X POST 'localhost:5601/api/saved_objects/index-pattern/logs-otel-v1?overwrite=true' \
      -H 'osd-xsrf: true' -H 'Content-Type: application/json' \
      -d '{"attributes":{"title":"logs-otel-v1","timeFieldName":"@timestamp","name":"otel logs"}}' \
      | grep -q '^2'; then ok=1; break; fi
    sleep 2
  done
  [ $ok -eq 1 ] || echo "WARN: dashboards not ready — data view not created (do it manually in OS Dashboards)"

  find_kubeconfig

  say "3/4  helm upgrade --install $RELEASE (backend=opensearch → host.docker.internal)"
  helm --kubeconfig="$KUBECONFIG_FILE" dependency update "$CHART" >/dev/null
  helm --kubeconfig="$KUBECONFIG_FILE" upgrade --install "$RELEASE" "$CHART" \
    --namespace "$OBSERVED_NS" --create-namespace \
    --set backend=opensearch \
    --set opensearch.endpoint=http://host.docker.internal:9200 \
    --set observedNamespace="$OBSERVED_NS" \
    --set annotationKey="" \
    --timeout 5m || { echo "ERROR: helm install failed"; exit 1; }

  K rollout status ds/${RELEASE}-opentelemetry-collector-agent -n "$OBSERVED_NS" --timeout=180s \
    || { echo "ERROR: collector not ready — K logs ds/${RELEASE}-opentelemetry-collector-agent"; exit 1; }

  say "4/4  port-forward :8889 -> collector :8889 (Prometheus scrape source)"
  bind_pf

  cat <<EOF

  UP ✓   (no logins anywhere — security plugins disabled)

  METRICS — http://localhost:9090  (Graph tab)
    k8s_pods_running                                             # running pods, value = count per resource_namespace
    sum(k8s_pods_running)                                        # cluster-wide total
    k8s_pods_running{resource_namespace="$OBSERVED_NS"}          # just odg components
    avg(system_cpu_utilization_ratio)                            # mean CPU % across cores
    Status → Targets: 'otel-collector' should be UP

  LOGS — http://localhost:5601   (OS Dashboards, no password)
    data view 'logs-otel-v1' is pre-created — open menu → Discover.
    ALL $OBSERVED_NS pod logs flow (annotation gate off — annotationKey="").

  RAW / debug:
      curl -s localhost:9200/logs-otel-v1/_count
      curl -s 'localhost:9090/api/v1/query?query=k8s_pods_running'
      ./telemetry.sh status
EOF
}

bind_pf() {
  # Only kill kubectl port-forward processes we own — never kill arbitrary
  # processes bound to :8889 (Docker Desktop's port proxy listens there and
  # killing it crashes the whole docker daemon on macOS).
  pkill -f 'kubectl.*port-forward.*8889:8889' 2>/dev/null || true; sleep 1
  nohup bash -c '
    K=/tmp/odg-telemetry-wl.kubeconfig
    while true; do
      pod=$(kubectl --kubeconfig="$K" -n '"$OBSERVED_NS"' get pod -l app.kubernetes.io/name=opentelemetry-collector --field-selector=status.phase=Running -o jsonpath="{.items[0].metadata.name}" 2>/dev/null)
      if [ -n "$pod" ]; then
        kubectl --kubeconfig="$K" -n '"$OBSERVED_NS"' port-forward "pod/$pod" 8889:8889 >>/tmp/pf-otel-metrics.log 2>&1
      fi
      sleep 2
    done' >/dev/null 2>&1 &
  disown
  sleep 3
  lsof -i tcp:8889 >/dev/null 2>&1 || echo "WARN: :8889 not bound yet — the loop keeps retrying"
}

cmd_down() {
  say "removing chart + port-forward"
  if wl="$(kind get clusters 2>/dev/null | grep '^workload-odg' | head -1)"; then
    kind get kubeconfig --name "$wl" > /tmp/odg-telemetry-wl.kubeconfig 2>/dev/null || true
    KUBECONFIG_FILE=/tmp/odg-telemetry-wl.kubeconfig
    helm --kubeconfig="$KUBECONFIG_FILE" uninstall "$RELEASE" -n "$OBSERVED_NS" --ignore-not-found || true
    # metrics-operator CRDs are in the chart's crds/ — helm doesn't reap them on
    # uninstall; drop explicitly so re-installs don't wedge on half-migrated CRDs.
    K delete crd metrics.open-control-plane.io datasinks.metrics.open-control-plane.io \
      remoteclusteraccesses.metrics.open-control-plane.io federatedclusteraccesses.metrics.open-control-plane.io \
      managedmetrics.metrics.open-control-plane.io federatedmetrics.metrics.open-control-plane.io \
      federatedmanagedmetrics.metrics.open-control-plane.io --ignore-not-found 2>/dev/null || true
    pkill -f 'kubectl.*port-forward.*8889:8889' 2>/dev/null || true
  else
    say "kind cluster not found — skipping cluster-side teardown"
  fi
  say "stopping backends"
  docker compose -f "$HERE/compose.yml" down
  echo "  DOWN ✓  (data kept — ./telemetry.sh reset to wipe)"
}

cmd_status() {
  say "port-forward (:8889 collector metrics):"
  lsof -i tcp:8889 >/dev/null 2>&1 && echo "  up" || echo "  down"
  echo
  say "backends (Docker):"
  docker compose -f "$HERE/compose.yml" ps --format 'table {{.Name}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null \
    | grep -E 'odg-telemetry|NAME' || echo "  (not running)"
  echo
  say "endpoints:"
  curl -s -o /dev/null -w '  prometheus  %{http_code}\n' localhost:9090/-/ready || echo "  prometheus  down"
  curl -s -o /dev/null -w '  opensearch  %{http_code}\n' localhost:9200        || echo "  opensearch  down"
  curl -s -o /dev/null -w '  dashboards  %{http_code}\n' localhost:5601/api/status || echo "  dashboards  down"
  echo
  if name="$(kind get clusters 2>/dev/null | grep '^workload-odg' | head -1)"; then
    say "workload pods in $OBSERVED_NS ($name):"
    kind get kubeconfig --name "$name" > /tmp/odg-telemetry-wl.kubeconfig 2>/dev/null
    kubectl --kubeconfig=/tmp/odg-telemetry-wl.kubeconfig get pods -n "$OBSERVED_NS" --no-headers 2>/dev/null \
      | grep -E 'opentelemetry|metrics-operator' || echo "  (chart not installed — run ./telemetry.sh up)"
  fi
}

cmd_reset() {
  say "wiping all telemetry data"
  docker compose -f "$HERE/compose.yml" down -v
  cmd_up
}

cmd_restart() { cmd_down; cmd_up; }

case "${1:-}" in
  up)      cmd_up ;;
  restart) cmd_restart ;;
  down)    cmd_down ;;
  status)  cmd_status ;;
  reset)   cmd_reset ;;
  *) echo "usage: $0 {up|down|status|reset|restart}"; exit 1 ;;
esac
