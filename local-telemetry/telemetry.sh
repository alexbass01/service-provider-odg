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
# Namespace on the workload cluster where odg components (incl. otel-collector) live.
OBSERVED_NS=odg-system
# Namespace on the platform cluster where the service-provider-odg controller runs.
CONTROLLER_NS=openmcp-system
# ConfigMap name in CONTROLLER_NS carrying the values overlay.
VALUES_CM=telemetry-values
# Chart name in the ProviderConfig that we attach the overlay to.
CHART=otel-collector
# FQ resource name — both openmcp and odg define "providerconfigs" CRDs on platform;
# kubectl would otherwise pick the wrong one.
PC_RESOURCE=providerconfigs.odg.services.open-control-plane.io

need() { command -v "$1" >/dev/null || { echo "ERROR: $1 not found in PATH"; exit 1; }; }
need docker; need helm; need kubectl; need curl

say() { echo "▸ $*"; }

# ─── locate the kind workload cluster ────────────────────────────────────────
find_kubeconfigs() {
  local wl plat
  wl=$(kind get clusters 2>/dev/null | grep '^workload-odg' | head -1 || true)
  plat=$(kind get clusters 2>/dev/null | grep '^platform' | head -1 || true)
  [ -n "$wl" ]   || { echo "ERROR: no kind cluster named workload-odg* — run: task test-e2e -- --keep-clusters"; exit 1; }
  [ -n "$plat" ] || { echo "ERROR: no kind cluster named platform* — run: task test-e2e -- --keep-clusters"; exit 1; }
  kind get kubeconfig --name "$wl"   > /tmp/odg-telemetry-wl.kubeconfig || exit 1
  kind get kubeconfig --name "$plat" > /tmp/odg-telemetry-plat.kubeconfig || exit 1
  KUBECONFIG_FILE=/tmp/odg-telemetry-wl.kubeconfig
  PLATFORM_KUBECONFIG=/tmp/odg-telemetry-plat.kubeconfig
  if ! kubectl --kubeconfig="$KUBECONFIG_FILE" get nodes >/dev/null 2>&1; then
    echo "ERROR: workload cluster '$wl' not reachable. Still running? Then re-run task test-e2e."; exit 1
  fi
  if ! kubectl --kubeconfig="$PLATFORM_KUBECONFIG" get nodes >/dev/null 2>&1; then
    echo "ERROR: platform cluster '$plat' not reachable. Still running? Then re-run task test-e2e."; exit 1
  fi
  say "workload cluster: $wl    platform cluster: $plat"
}
K()       { kubectl --kubeconfig="$KUBECONFIG_FILE" "$@"; }
K_PLAT()  { kubectl --kubeconfig="$PLATFORM_KUBECONFIG" "$@"; }

# find_tenant_namespace returns the platform-cluster namespace that holds the
# tenant-scoped HelmReleases / OCIRepositories the controller manages.
find_tenant_namespace() {
  TENANT_NS=$(K_PLAT get helmreleases -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\n"}{end}' 2>/dev/null | sort -u | grep '^mcp--' | head -1)
  if [ -z "$TENANT_NS" ]; then
    echo "ERROR: no tenant namespace (mcp--*) with HelmReleases found on platform cluster — is the ODG instance reconciled?"
    exit 1
  fi
  say "tenant ns: $TENANT_NS"
}

cmd_up() {
  say "1/4  backends (Docker)"
  docker compose -f "$HERE/compose.yml" up -d

  say "2/5  waiting for opensearch (:9200) + prometheus (:9090)"
  local ok=0
  for _ in $(seq 1 60); do
    curl -s -o /dev/null localhost:9200 \
      && curl -s -o /dev/null localhost:9090/-/ready \
      && { ok=1; break; }
    sleep 2
  done
  [ $ok -eq 1 ] || { echo "ERROR: backends not ready after 2m. docker compose -f $HERE/compose.yml logs"; exit 1; }

  # Create the OpenSearch data view (index pattern) so Discover works out of the box.
  say "3/5  waiting for dashboards (:5601) + create 'logs-otel-v1' data view"
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

  find_kubeconfigs
  find_tenant_namespace

  # Workaround for ODG's default-deny NetworkPolicy: the metrics-operator chart
  # doesn't support extraManifests so we can't ship this via its ProviderConfig.
  # Apply before helm install so the operator's init container can reach the API.
  # The e2e test applies the same policy via telemetryNetworkPolicies() — any change
  # here should be mirrored there.
  cat <<'EOF' | K apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-egress-from-metrics-operator
  namespace: odg-system
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: metrics-operator
  policyTypes: [Egress]
  egress:
    - {}
EOF

  say "4/6  apply values overlay ConfigMap on platform ns=$CONTROLLER_NS"
  K_PLAT -n "$CONTROLLER_NS" create configmap "$VALUES_CM" \
    --from-file=values.yaml="$HERE/telemetry-values.yaml" \
    --dry-run=client -o yaml | K_PLAT apply -f -

  say "5/6  attach helmValuesFrom on ProviderConfig chart=$CHART"
  # find the index of the chart by name
  IDX=$(K_PLAT get $PC_RESOURCE odg -o json | python3 -c "
import json,sys
pc=json.load(sys.stdin)
for i,c in enumerate(pc['spec']['charts']):
    if c['chartName']=='$CHART': print(i); break
")
  [ -n "$IDX" ] || { echo "ERROR: chart $CHART not found in ProviderConfig"; exit 1; }
  K_PLAT patch $PC_RESOURCE odg --type=json -p="[{
    \"op\": \"add\",
    \"path\": \"/spec/charts/$IDX/helmValuesFrom\",
    \"value\": [{\"kind\": \"ConfigMap\", \"name\": \"$VALUES_CM\"}]
  }]"

  say "6/6  apply DataSink + Metric CRs, wait for helm upgrade of $CHART"
  K apply -f "$HERE/metrics-operator-cr.yaml" || exit 1
  # helm upgrade happens via the controller's next poll (default 1m) — wait for Ready=True
  # with the new observed generation. After Ready, pods rolupdate automatically.
  K_PLAT -n "$TENANT_NS" wait helmrelease "$CHART" --for=condition=Ready --timeout=5m

  say "opening port-forward :8889 -> collector :8889 in $OBSERVED_NS (for Prometheus scrape)"
  # Only kill kubectl port-forward processes we own — never kill arbitrary
  # processes bound to :8889 (Docker Desktop's port proxy listens there and
  # killing it crashes the whole docker daemon on macOS).
  pkill -f 'kubectl.*port-forward.*8889:8889' 2>/dev/null || true
  sleep 1
  K rollout status ds/${CHART}-agent -n "$OBSERVED_NS" --timeout=120s || { echo "ERROR: collector not ready"; exit 1; }
  bind_pf

  echo
  cat <<'EOF'

  UP ✓   (no logins anywhere — security plugins disabled)

  METRICS — http://localhost:9090  (Graph tab)
    metrics-operator metric (from Metric CR 'odg-pods-running', pushed via OTLP):
      odg_pods_running                                          # one line per pod
      count(odg_pods_running)                                   # total pods in odg-system
      count by (pod)(odg_pods_running)                          # one line per pod label
    grouping / rollup (host metrics):
      avg(system_cpu_utilization_ratio{state="user"})            # mean CPU % across cores
      avg by (cpu)(system_cpu_utilization_ratio)                # one line per core
    Status -> Targets: 'otel-collector' should be UP

  LOGS — http://localhost:5601   (OS Dashboards, no password)
    data view 'logs-otel-v1' is pre-created — just open menu -> Discover.
    filters:
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
  say "removing telemetry overlay + CRs (reverting $CHART to e2e default exporters)"
  if wl="$(kind get clusters 2>/dev/null | grep '^workload-odg' | head -1)" \
     && plat="$(kind get clusters 2>/dev/null | grep '^platform' | head -1)"; then
    kind get kubeconfig --name "$wl"   > /tmp/odg-telemetry-wl.kubeconfig 2>/dev/null || true
    kind get kubeconfig --name "$plat" > /tmp/odg-telemetry-plat.kubeconfig 2>/dev/null || true
    KUBECONFIG_FILE=/tmp/odg-telemetry-wl.kubeconfig
    PLATFORM_KUBECONFIG=/tmp/odg-telemetry-plat.kubeconfig

    K delete -f "$HERE/metrics-operator-cr.yaml" --ignore-not-found 2>/dev/null || true

    IDX=$(K_PLAT get $PC_RESOURCE odg -o json 2>/dev/null | python3 -c "
import json,sys
pc=json.load(sys.stdin)
for i,c in enumerate(pc['spec']['charts']):
    if c['chartName']=='$CHART': print(i); break
" 2>/dev/null)
    if [ -n "$IDX" ]; then
      K_PLAT patch $PC_RESOURCE odg --type=json \
        -p="[{\"op\": \"remove\", \"path\": \"/spec/charts/$IDX/helmValuesFrom\"}]" 2>/dev/null || true
    fi
    K_PLAT -n "$CONTROLLER_NS" delete configmap "$VALUES_CM" --ignore-not-found 2>/dev/null || true
    pkill -f 'kubectl.*port-forward.*8889:8889' 2>/dev/null || true
  else
    say "kind clusters not found — skipping cluster-side teardown"
  fi
  say "stopping backends"
  docker compose -f "$HERE/compose.yml" down
  echo "  DOWN v  (data kept — use ./telemetry.sh reset to wipe)"
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
    say "workload pods in $OBSERVED_NS ($name):"
    kind get kubeconfig --name "$name" > /tmp/odg-telemetry-wl.kubeconfig 2>/dev/null
    kubectl --kubeconfig=/tmp/odg-telemetry-wl.kubeconfig get pods -n "$OBSERVED_NS" --no-headers 2>/dev/null \
      | grep -E 'otel|metrics-operator' || echo "  (not installed)"
    say "overlay ConfigMap on platform:"
    plat=$(kind get clusters 2>/dev/null | grep '^platform' | head -1)
    kind get kubeconfig --name "$plat" > /tmp/odg-telemetry-plat.kubeconfig 2>/dev/null
    kubectl --kubeconfig=/tmp/odg-telemetry-plat.kubeconfig -n "$CONTROLLER_NS" get configmap "$VALUES_CM" --no-headers 2>/dev/null \
      || echo "  (not applied — run ./telemetry.sh up)"
  fi
}

cmd_reset() {
  say "wiping all telemetry data"
  docker compose -f "$HERE/compose.yml" down -v
  cmd_up
}

# (re)bind :8889 to the current collector pod. Resolves the pod by label each loop-iteration,
# so if the daemonset pod is recreated the forward follows it automatically.
bind_pf() {
  pkill -f 'kubectl.*port-forward.*8889:8889' 2>/dev/null || true; sleep 1
  nohup bash -c '
    K=/tmp/odg-telemetry-wl.kubeconfig
    while true; do
      pod=$(kubectl --kubeconfig="$K" -n odg-system get pod -l app.kubernetes.io/name=opentelemetry-collector --field-selector=status.phase=Running -o jsonpath="{.items[0].metadata.name}" 2>/dev/null)
      if [ -n "$pod" ]; then
        kubectl --kubeconfig="$K" -n odg-system port-forward "pod/$pod" 8889:8889 >>/tmp/pf-otel-metrics.log 2>&1
      fi
      sleep 2
    done' >/dev/null 2>&1 &
  disown
  sleep 3
  lsof -i tcp:8889 >/dev/null 2>&1 || echo "WARN: :8889 not bound yet — the loop keeps retrying"
}

cmd_restart() {
  cmd_down   # tears down cluster releases + CRs + port-forward + backends
  cmd_up     # reinstalls everything + rebinds the (self-healing) port-forward
}

case "${1:-}" in
  up)     cmd_up ;;
  restart) cmd_restart ;;
  down)   cmd_down ;;
  status) cmd_status ;;
  reset)  cmd_reset ;;
  *) echo "usage: $0 {up|down|status|reset}"; exit 1 ;;
esac
