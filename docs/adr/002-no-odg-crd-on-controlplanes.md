# ADR-002: Not Running the ODG CRD on OCP ControlPlanes as DomainServiceAPI

- **Status:** Rejected
- **Date:** 2025-08-31

## Context

An alternative integration model would have been to install the existing ODG
CRD onto OCP ControlPlanes as a DomainServiceAPI, reusing the ODG operator as
a DomainService.

## Decision

Rejected. The ODG CRD is not installed on ControlPlanes; ODG instances are
ordered through a dedicated resource on the onboarding cluster instead.

## Alternatives Considered

- **DomainServiceAPI on ControlPlanes** — rejected for the reasons below.

## Consequences

Reasons for rejection:

- Running multiple ODG instances via this model is not desirable (no data
  sharing between them).
- It adds another ordering layer on top of OCP's built-in one, increasing
  complexity.
- OCP Workspaces should be leveraged for multi-landscape setups instead.

Follow-up:

- The onboarding flow is owned by ODG's own controller (see
  [ADR-0002](0002-plugin-not-serviceprovider.md)).
