# Architecture

This folder contains a lightweight architecture overview for the ODG Service
Provider, plus the Architecture Decision Records (ADRs).

For anything beyond this
overview, decisions are captured as individual ADRs.

## Introduction and Goals

The ODG Service Provider integrates [Open Delivery Gear (ODG)](https://github.com/open-component-model/open-delivery-gear)
with [OpenControlPlane (OCP)](https://github.com/openmcp-project), so users
can request and consume managed ODG instances through the OCP onboarding API.

ODG is a Kubernetes-native compliance automation engine for continuous
security and compliance scanning of OCM components. The goal is to make ODG
available as a **plugin on top of OCP** — users request an ODG instance via
the OCP onboarding API, OCP provisions the infrastructure, and ODG runs on a
dedicated workload cluster.

### Quality Goals

| Priority | Quality Goal | Description |
|---|---|---|
| 1 | **Isolation** | Each ODG tenant runs on its own workload cluster — no shared blast radius. |
| 2 | **Self-service** | Users request ODG instances via the standard OCP Kubernetes API without manual operator intervention. |
| 3 | **Reusability** | ODG reuses OCP infrastructure (Flux, ESO, observability) or Gardener features (DNS, cert management) rather than building its own. |
| 4 | **Deployability** | ODG uses the same deployment mechanisms as OCP (OCM components, Flux). |
| 5 | **Security** | Shared security concept with OCP; no separate security programme. |

## Constraints

- **OCP is the host platform.** ODG is a plugin on top of OCP — it must be
  installable after OCP is already running, not the other way around.
- **Same deployment mechanisms.** ODG must use OCM components and Flux
  Kustomizations/HelmReleases — the same tooling OCP itself uses.
- **Gardener Shoot clusters.** ODG workloads run on Gardener Shoots, managed
  through OCP's cluster lifecycle. ODG does not bring its own cluster
  management.
- **No heavy workloads on declaration layers.** Scanners, databases, and UIs
  run on workload clusters, never on the ControlPlane, PlatformCluster, or
  OnboardingCluster.
- **Shared security model.** No separate security programme; ODG reuses OCP's
  security concept.
- **ControlPlane not necessary** ODG will not use a ControlPlane and does not need one
  to be functional as all ordering + config happens in the onboarding cluster.

## Context
The end user interacts exclusively with the OCP onboarding API. ODG instances
are ordered as a resource on the onboarding cluster; the ODG service provider
controller deploys the ODG stack onto a dedicated workload cluster.

## Cross-cutting Concepts

- **Auth:** Trial — GitHub OIDC; Beta — IAM/CAM tenant (GitHub OIDC as
  fallback).
- **Observability:** Ship logs to the central logging instance on the platform
  cluster; do not run a separate observability stack.
- **Secrets:** External Secrets Operator (ESO) syncs credentials from external
  vaults into Kubernetes Secrets.
- **DNS & Certificates:** Trial — Gardener Shoot default domain; Beta —
  proper external URL with Gardener-managed DNS and certificate manager.
- **Backup & Restore:** Trial — self-managed DB, own backup; Beta — automated
  backup / manual restore with runbooks.
- **Metering:** ODG instance usage time is tracked via OCP's metering
  infrastructure.

## Risks and Technical Debts

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| VPN connectivity to corporate networks (CIDR conflicts, route permissions) | Medium | High | Under investigation: BTP Proxy, Gateway, OCP CIDR tooling. |
| Managed database provisioning for Beta unclear (BTP, RDS, HANA) | Medium | Medium | Investigate in Beta; Crossplane/Provider BTP as candidate. |
| Observability gaps (metrics/tracing not yet ready on OCP) | High | Medium | Coordinate with OCP team; ship to central backends when available. |
| IAM/CAM tenant availability for Beta may be delayed | Medium | Medium | GitHub OIDC as fallback. |
| Per-tenant Flux may increase operational overhead at scale | Low | Medium | Central Flux as fallback. |
| ODG resource footprint may be too large for efficient scale-out | Medium | Medium | ODG team to prioritise footprint reduction. |
| L1 (OCP) / L2+L3 (ODG) support split not yet operated | Medium | Medium | Define clear escalation paths; knowledge transfer sessions. |

## Architecture Decision Records

Decisions are recorded as ADRs in `docs/adr/`. To add a new one, copy `000-template.md` to the next number.


## Glossary

| Term | Definition |
|---|---|
| **OCP** | Open Control Plane — platform providing each team a dedicated Kubernetes API (ControlPlane) to declare their landscape as CRDs. |
| **ODG** | Open Delivery Gear — Kubernetes-native compliance automation engine for continuous scanning of OCM components. |
| **OCM** | Open Component Model — semantic model for describing software components and their transport. |
| **Onboarding Cluster** | Shared OCP cluster where users create Projects, Workspaces, and order services like ODG. |
| **Platform Cluster** | Shared OCP cluster where service provider controllers and the openmcp-operator run. |
| **Workload Cluster** | Kubernetes cluster (e.g., Gardener Shoot) where heavy workloads run. |
| **Workload-ODG Cluster** | Dedicated cluster type for ODG tenants with its own Shoot template. |
| **Shoot** | A Gardener-managed Kubernetes cluster. |
| **Flux** | GitOps tool reconciling Kustomizations and HelmReleases to deploy workloads. |
| **ESO** | External Secrets Operator — syncs secrets from external vaults into Kubernetes Secrets. |
| **BacklogItem** | ODG Custom Resource representing queued work for a scanner extension. |
| **mODG** | Managed ODG — an ODG instance provisioned and operated through OCP. |
