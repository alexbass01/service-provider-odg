# local-telemetry — local OTel dev stack

Standalone dev helper for ODG telemetry. **Not** wired into `task test-e2e`; it runs against
the *retained* kind clusters that `--keep-clusters` leaves behind.

```
backends (your Mac, Docker)          workload-odg kind cluster
┌──────────────────────────┐         ┌────────────────────────────────────────┐
│ prometheus   :9090       │──scrape──► localhost:8889 (kubectl port-forward) │──► otel-collector :8889
│ opensearch   :9200       │◄──push── otel-collector (daemonset)             │
│ dashboards   :5601       │         │   filelog / k8sattributes              │
└──────────────────────────┘         │   metrics-operator (counts CRs)        │
                                     └────────────────────────────────────────┘
```

Metrics flow by **pull**: Prometheus on the Mac scrapes the collector's `:8889` through a
`kubectl port-forward` opened by `telemetry.sh` — no Docker Desktop host-reachability needed.
Logs/traces still push to OpenSearch via `host.docker.internal` (Docker Desktop's host gateway).
The metrics-operator counts ODG resources (see `metrics-operator-cr.yaml`) and pushes OTLP to
the collector (`:4317`); the collector re-exports them on `:8889`.

## Commands

```bash
cd local-telemetry
./telemetry.sh up       # start backends + install collector/metrics-operator + apply CRs
./telemetry.sh status   # is anything up?
./telemetry.sh down     # remove collector/CRs, stop backends (data kept)
./telemetry.sh reset    # wipe all data, start fresh
```

## Prerequisites

`task test-e2e -- --keep-clusters` must have run and still be alive (kubeconfig is auto-discovered
from `kind get clusters`).

## Verify data lands

- Prometheus: http://localhost:9090 → **Status → Targets** shows `otel-collector (localhost:8889)` **UP**
  once the port-forward is live. Metric series (e.g. `odg_pods_running`, `system_cpu_utilization_ratio`)
  appear in **Graph** within ~1 min of `up`.
- Dashboards: http://localhost:5601 (no login) → **Dev Tools** → `GET logs-otel-v1/_search`

## Notes

- Logs are only collected from pods annotated `otel.io/pod-logs: "true"` in `odg-system`
  (see `collector-values.yaml` → `filter/only_annotated`). Annotate a workload to opt it in:
  `kubectl -n odg-system annotate pod <pod> otel.io/pod-logs=true --overwrite`
- Backends run with security disabled (lab mode). SAP/BTP production uses mTLS — see
  `~/code/discussions/12-otel/04-btp-metrics-view.md`.
