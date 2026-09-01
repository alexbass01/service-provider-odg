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
| 3 | **Reusability** | ODG reuses OCP infrastructure (Flux, DNS, cert management, ESO, observability) rather than building its own. |
| 4 | **Deployability** | ODG uses the same deployment mechanisms as OCP (OCM components, kro RGDs, Flux). |
| 5 | **Security** | Shared security concept with OCP; no separate security programme. |

### Stakeholders

| Role | Expectations |
|---|---|
| ODG Team | Owns ODG product, L2/L3 support, operating procedures, usage targets |
| OCP Team | Owns L1 support, platform infrastructure, cluster lifecycle, onboarding API |
| End Users | Self-service ODG provisioning, accessible UI, reliable scanning |

## Constraints

- **OCP is the host platform.** ODG is a plugin on top of OCP — it must be
  installable after OCP is already running, not the other way around.
- **Same deployment mechanisms.** ODG must use OCM components, kro RGDs, and
  Flux Kustomizations/HelmReleases — the same tooling OCP itself uses.
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

```
                    ┌──────────────────────────────────────────┐
                    │              OCP Platform                │
                    │                                          │
  End User ────────►│  Onboarding API                          │
  (kubectl)         │  └─► Project → Workspace → ODG instance  │
                    │                                          │
                    │  ODG Service Provider (plugin)           │
                    │  └─► Provisions ODG workload cluster     │
                    │      └─► Deploys ODG on workload         │
                    └──────────────────────┬───────────────────┘
                                           │
                    ┌──────────────────────▼───────────────────┐
                    │           ODG Workload Cluster           │
                    │                                          │
                    │  ODG Core API  ·  ODG UI  ·  ODG DB      │
                    │  Scanner Extensions  ·  Backlog Controller│
                    └──────┬─────────────┬─────────────────────┘
                           │             │
                    ┌──────▼───┐   ┌─────▼──────────┐
                    │ OCM Reg. │   │ Corporate Net  │
                    │(artefacts)│  │ (VPN, internal │
                    └──────────┘   │  services)     │
                                   └────────────────┘
```

The end user interacts exclusively with the OCP onboarding API. ODG instances
are ordered as a resource on the onboarding cluster; the ODG service provider
controller deploys the ODG stack onto a dedicated workload cluster.

| Channel | Direction | Technology |
|---|---|---|
| User → OCP Onboarding API | Inbound | Kubernetes API (kubectl) |
| OCP → Gardener | Outbound | Gardener API (provision Shoots) |
| ODG Workload → OCM Registry | Outbound | OCM protocol (fetch component descriptors) |
| ODG Workload → Corporate Network | Outbound | VPN / BTP Proxy (internal services) |
| OCP → User | Outbound | Shoot default domain / external URL (HTTP) |
| ODG → OCP Observability | Outbound | Central logging instance on platform cluster |
| OCP → ODG Secrets | Inbound | External Secrets Operator (ESO) / Vault |

## Building Blocks (Level 1)

```
┌─────────────────────────────────────────────────────────────────┐
│                        OCP + ODG System                         │
│                                                                 │
│  ┌─────────────────┐   ┌──────────────────┐   ┌──────────────┐  │
│  │  Onboarding API  │   │  OCP Operator     │   │  ODG Service│ │
│  │  (shared)        │   │  & Lifecycle Mgr  │   │  Provider   │ │
│  │                  │   │  (shared)         │   │  (plugin)   │ │
│  └────────┬────────┘   └────────┬─────────┘   └──────┬───────┘  │
│           │                     │                    │          │
│           ▼                     ▼                    ▼          │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │              OCP Cluster Management                       │  │
│  │  (Gardener ClusterProvider, Shoot lifecycle, profiles)    │  │
│  └───────────────────────────┬───────────────────────────────┘  │
│                              │                                  │
│           ┌──────────────────┼──────────────────┐               │
│           ▼                  ▼                  ▼               │
│  ┌──────────────┐  ┌──────────────┐  ┌────────────────────┐     │
│  │ ControlPlane  │  │ Workload      │  │ ODG Workload       │    │
│  │ (per tenant)  │  │ Cluster (reg) │  │ Cluster (per tenant)│   │
│  │ Crossplane    │  │               │  │ ODG Core + UI + DB │    │
│  │ Flux          │  │               │  │ Scanner Extensions │    │
│  └──────────────┘  └──────────────┘  └────────────────────┘     │
└─────────────────────────────────────────────────────────────────┘
```

| **Name** | **Responsibility** |
|---|---|
| Onboarding API | Shared OCP Kubernetes API where users create Projects, Workspaces, and order ODG instances |
| OCP Operator & Lifecycle Manager | Manages ControlPlanes, workload clusters, and their lifecycle on the platform cluster |
| ODG Service Provider | Watches onboarding cluster for ODG instance requests; provisions workload clusters and deploys ODG |
| OCP Cluster Management | Gardener ClusterProvider; creates/modifies/deletes Shoot clusters with profiles (e.g., `workload-odg`) |
| ControlPlane (per tenant) | Optional: hosts Crossplane CRDs/controllers for managing external deps (DBs, VPNs) |
| ODG Workload Cluster (per tenant) | Dedicated Gardener Shoot running the full ODG stack: Core API, UI, DB, scanners |

### ODG Workload Cluster (Level 2)

```
ODG Workload Cluster (Gardener Shoot, per tenant)
┌─────────────────────────────────────────────────────┐
│  Namespace: odg-system                              │
│                                                     │
│  ┌──────────┐  ┌──────────┐  ┌──────────────────┐   │
│  │ ODG Core  │  │ ODG UI  │  │ ODG DB (managed) │   │
│  │ (API)     │  │ (react) │  │                  │   │
│  └─────┬────┘  └────┬─────┘  └────────┬─────────┘   │
│        │            │                 │             │
│  ┌─────▼────────────▼─────────────────▼───────────┐ │
│  │          Artefact Enumerator (CronJob)         │ │
│  └─────────────────────┬──────────────────────────┘ │
│                        │                            │
│  ┌─────────────────────▼──────────────────────────┐ │
│  │       Backlog Controller (Deployment)          │ │
│  └─────────────────────┬──────────────────────────┘ │
│                        │                            │
│  ┌─────────┐ ┌────────┐ ┌─────────┐ ┌──────────┐    │
│  │ Scanner │ │ Scanner │ │ Scanner │ │ Issue    │   │
│  │ (BDBA)  │ │ (ClamAV)│ │ (SBoM)  │ │Replicator│   │
│  └─────────┘ └────────┘ └─────────┘ └──────────┘    │
└─────────────────────────────────────────────────────┘
```

Components are deployed via Flux HelmReleases. Scanners are scaled by the
Backlog Controller based on queue depth.

## Cross-cutting Concepts

- **Auth:** Trial — GitHub OIDC; Beta — IAM/CAM tenant (GitHub OIDC as
  fallback).
- **Observability:** Ship logs to the central logging instance on the platform
  cluster; do not run a separate observability stack.
- **Secrets:** External Secrets Operator (ESO) syncs credentials from external
  vaults into Kubernetes Secrets.
- **DNS & Certificates:** Trial — Gardener Shoot default domain; Beta —
  proper external URL with Gardener-managed DNS and certificate manager.
- **GitOps:** ODG components deploy as OCM components via Flux
  HelmReleases/Kustomizations. Per-workload-cluster Flux preferred over
  central Flux for scalability.
- **Backup & Restore:** Trial — none (self-managed DB); Beta — automated
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

Decisions are recorded as ADRs in [`adrs/`](adrs/). To add a new one, copy
[`adrs/0000-adr-template.md`](adrs/0000-adr-template.md) to the next number.

| # | Title | Status |
|---|---|---|
| [0001](adrs/0001-dedicated-workload-cluster-type.md) | Dedicated Workload Cluster Type (`workload-odg`) | Accepted |
| [0002](adrs/0002-plugin-not-serviceprovider.md) | Plugin, Not a ServiceProvider in OCP Terms | Accepted |
| [0003](adrs/0003-no-odg-crd-on-controlplanes.md) | No ODG CRD on OCP ControlPlanes as DomainServiceAPI | Rejected |
| [0004](adrs/0004-self-managed-db-trial-managed-db-beta.md) | Self-Managed Database for Trial, Managed DB for Beta | Accepted |
| [0005](adrs/0005-per-tenant-flux.md) | Per-Tenant Flux over Central Flux | Proposed |

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

The full, more verbose arc42-style source document this overview was
distilled from is `combined.md` in the repository root.
