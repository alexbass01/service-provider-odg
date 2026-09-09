# ADR-004: Use SAP BTP as the Managed Database Provider

| Status   | Proposed                                      |
|----------|-----------------------------------------------|
| Date     | 2026-09-09                                    |

## Context and Problem Statement

ODG Beta requires a production-grade managed database. The platform runs
across multiple SAP environments, cloud providers, and regions. We need a
managed Postgres offering that works across all of them without us operating
infrastructure credentials per hyperscaler.

## Decision Drivers

* **Multi-environment coverage**: must work on AWS, Azure, Google Cloud, and
  SAP sub-cloud (SCI).
* **No DIY infrastructure**: we should not manage cloud-provider accounts,
  keys, or backup configurations ourselves.
* **Operational simplicity**: provisioning, backups, audit logging and upgrades should be
  handled by the provider.

## Considered Options

1. **SAP BTP** — BTP abstracts Postgres creation across hyperscalers (Azure
   Flexible Server, AWS RDS, etc.) and SAP's own SCI via Cloud Foundry.
2. **Own hyperscaler accounts** — provision Postgres directly in each
   hyperscaler using our own credentials per region/provider.

## Decision Outcome

Chosen option: **"SAP BTP"**, because it abstracts away per-hyperscaler
account management and covers all target environments from a single control
plane.

## Consequences

Positive:

- Single provisioning API across AWS, Azure, GCP, and SCI.
- Hyperscaler-native services under the hood (RDS, Flexible Server, etc.) —
  no custom backup/HA needed.

Negative / follow-up:

- **Network access is unresolved** — connectivity from ODG workload clusters
  to BTP-provisioned databases needs investigation per environment:
  - Azure: worked from a public IP.
  - AWS: connectivity works but RDS uses a non-standard port — the port from
    the BTP credentials must be used explicitly (not the Postgres default 5432).
  - SCI (Cloud Foundry): not reachable from VPN or corporate network; may
    require a jump host or CF proxy.
  - Need to also to investigate how to provision stable outbound IPs for workload clusters
