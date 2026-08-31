# ADR-0001: ODG Uses a Dedicated Workload Cluster Type (`workload-odg`)

- **Status:** Accepted
- **Date:** 2025-08-31

## Context

ODG could either share existing OCP workload clusters with other tenants or
get its own cluster purpose. ODG has specific infrastructure needs (sizing,
ingress, DNS, resource management) and benefits from isolation between
tenants.

## Decision

ODG gets a dedicated workload cluster type `workload-odg` with its own Shoot
template and an optional separate Gardener project.

## Alternatives Considered

- **Share existing OCP workload clusters** — rejected: no fine-tuned
  infrastructure for ODG, shared blast radius with other tenants, and no
  separate cost/access isolation.

## Consequences

Positive:

- Fine-tuned infrastructure without affecting OCP workload.
- Independent tenancy scaling.
- Separate Gardener project for access/cost/alerting isolation.
- Independent tooling (ingress, DNS, resource manager).

Negative / follow-up:

- One more cluster type to maintain — overhead is minimal since OCP's
  scheduler already supports arbitrary cluster purposes (configuration change
  only).
