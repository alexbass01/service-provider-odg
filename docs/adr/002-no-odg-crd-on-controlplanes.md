# ADR-002: No ODG CRD on OCP ControlPlanes as DomainServiceAPI

| Status   | Accepted   |
|----------|------------|
| Date     | 2025-08-31 |

## Context and Problem Statement

Most other ServiceProviders install a CRD (DomainServiceAPI) on the control
plane they are selected for. The question is whether ODG follows this model
or manages without a ControlPlane entirely.

## Decision Drivers

* **Simplicity**: avoid an additional ordering layer on top of OCP's built-in
  one.
* **Fit for purpose**: running multiple ODG instances via the ControlPlane
  model is not desirable (no data sharing between them).

## Considered Options

1. **DomainServiceAPI on ControlPlanes** — user orders a control plane,
   installs the ODG Service Provider, creates the ODG config in the control
   plane, and ODG gets instantiated with this config.
2. **No ControlPlane** — user puts all settings into the onboarding cluster
   and ODG gets instantiated through the service provider. The service URL is
   passed back into the onboarding cluster, independent of any control planes.

## Decision Outcome

Chosen option: **"No ControlPlane"**, because running multiple ODG instances
via the ControlPlane model is not desirable (no data sharing between them) and
it adds another ordering layer on top of OCP's built-in one, increasing
complexity. The ODG CRD is not installed on ControlPlanes; ODG instances are
ordered through a dedicated resource on the onboarding cluster instead.
