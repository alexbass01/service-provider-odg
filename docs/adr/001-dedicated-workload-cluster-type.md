# ADR-001: ODG Uses a Dedicated Workload Cluster Type (`workload-odg`)

| Status   | Accepted   |
|----------|------------|
| Date     | 2025-08-31 |

## Context and Problem Statement

ODG could either share existing OCP workload clusters with other tenants or
get its own cluster purpose. ODG has specific infrastructure needs (sizing,
gateway, DNS, resource management) and benefits from isolation between
tenants.

## Decision Drivers

* **Isolation**: no shared blast radius with other tenants; separate
  cost/access isolation.
* **Infrastructure fit**: ODG needs fine-tuned sizing, gateway, DNS, and
  resource management without affecting OCP workload.
* **Statefulness**: existing OCP workload clusters are designed to be
  stateless (state is only persisted in etcd, no databases etc.).

## Considered Options

1. **Dedicated workload cluster type `workload-odg`** — own Shoot template and
   an optional separate Gardener project.
2. **Share existing OCP workload clusters** with other tenants.

## Decision Outcome

Chosen option: **"Dedicated workload cluster type `workload-odg`"**, because
sharing existing clusters would mean no fine-tuned infrastructure for ODG, a
shared blast radius with other tenants, and no separate cost/access isolation.

## Consequences

Positive:

- Fine-tuned infrastructure without affecting OCP workload.
- Independent scaling.
- Separate Gardener project for access/cost/alerting isolation possible.
- Independent tooling (gateway, DNS, cert manager).

Negative / follow-up:

- One more cluster type to maintain — overhead is minimal since OCP's
  scheduler already supports arbitrary cluster purposes (configuration change
  only).
