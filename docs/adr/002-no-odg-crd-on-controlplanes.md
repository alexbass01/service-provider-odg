# ADR-002: No ODG CRD on OCP ControlPlanes as DomainServiceAPI

- **Status:** Accepted
- **Date:** 2025-08-31

## Context

Most other ServiceProviders install a CRD (DomainServiceAPI) on the control plane they are selected for. 

Option 1: User orders control plane, installs ODG Service Provider, user created ODG config in control plane and then ODG gets instantiated with this config.

Opion 2: User doesn't need need a ControlPlane for ODG, puts all settings into the onboarding cluster and ODG gets instanciated through the service provider.
The service URL will be passed back into the onboarding cluster independent of any control planes.

## Decision

The ODG CRD is not installed on ControlPlanes; ODG instances are ordered
through a dedicated resource on the onboarding cluster instead.


## Consequences

Reasons for rejection:

- Running multiple ODG instances via this model is not desirable (no data
  sharing between them).
- It adds another ordering layer on top of OCP's built-in one, increasing
  complexity.
