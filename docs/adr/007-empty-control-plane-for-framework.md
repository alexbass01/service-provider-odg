# ADR-007: Require an Empty ControlPlane for the ODG Service Offering (for Now)

| Status   | Proposed                                      |
|----------|-----------------------------------------------|
| Date     | 2026-09-09                                    |

## Context and Problem Statement

ADR-002 established that ODG does not use a ControlPlane as its domain API —
all ordering happens on the onboarding cluster. ADR-006 further established
that databases are provisioned centrally on an ODG-owned ControlPlane, not on
a per-tenant one. Individual tenant ControlPlanes need neither ODG CRDs nor
any Crossplane/BTP configuration. Architecturally, ODG therefore does not need
a per-tenant ControlPlane at all. However, the current OCP framework and
tooling are built around the standard service provider model, which assumes a
ControlPlane exists and is `Ready`. We need to decide whether to work within
that assumption or invest in a custom path now.

## Decision Drivers

* **Framework fit**: the standard OCP service provider template, E2E test
  suite, and UI visibility all require a ControlPlane to be present and `Ready`.
* **Time to delivery**: writing a custom controller to bypass the ControlPlane
  requirement is non-trivial and would need alignment with the OCP team
  (Christopher).
* **Architectural cleanliness**: from a pure architecture standpoint, ODG
  could run with just a CRD on the onboarding cluster — no ControlPlane needed.
  This is a viable future state, not the current one.

## Considered Options

1. **Require an empty ControlPlane** — ODG orders a ControlPlane as part of
   its provisioning flow. The ControlPlane carries no ODG-specific CRDs and no
   Crossplane/BTP setup (databases live on the central ODG ControlPlane per
   ADR-006); it exists purely to satisfy the framework. Reuses the standard SP
   template, UI integration, and E2E tests unchanged.
2. **Skip the ControlPlane entirely** — place only a CRD on the onboarding
   cluster and write a custom controller that does not depend on a ControlPlane
   being present. Requires OCP team coordination and significant upfront
   investment.

## Decision Outcome

Chosen option: **"Require an empty ControlPlane"**, because it lets us use the
standard service provider template, appear correctly in the OCP UI, and run the
existing E2E tests without changes. The architectural overhead is low — the
ControlPlane is empty and exists only as a framework placeholder.

Skipping the ControlPlane is architecturally valid but requires a custom
controller and OCP team alignment. This can be revisited once the offering is
stable.

## Consequences

Positive:

- Standard SP template and tooling work without modification.
- ODG instances appear in the OCP UI out of the box.
- E2E tests run against the standard flow.
- No OCP team coordination needed now.

Negative / follow-up:

- Each ODG tenant gets an empty ControlPlane that serves no functional purpose
  — no CRDs, no Crossplane, no BTP config; minor resource overhead only.
- Revisit once the offering is stable: running without a ControlPlane would
  simplify the tenant lifecycle and reduce resource usage.
- If OCP changes the standard SP model, this assumption may need revisiting
  sooner.
