# ADR-003: Self-Managed Database for Trial, Managed DB Investigated for Beta

| Status   | To be discussed — Beta decision under investigation |
|----------|-----------------------------------------------------|
| Date     | 2025-08-31                                          |

## Context and Problem Statement

ODG requires a database for persistence. For the Trial phase, speed of
delivery and simplicity matter more than operational maturity. For Beta, a
production-grade database with backup/restore is required.

## Decision Drivers

* **Time to delivery**: Trial must ship quickly; the managed-DB provisioning
  mechanism (BTP, RDS, HANA) is not yet clarified.
* **Operational maturity**: Beta requires production-grade backup/restore.

## Considered Options

1. **Self-managed database for Trial, managed DB for Beta** — StatefulSet with
   a PVC on the ODG workload cluster for Trial; managed database provisioned
   via Crossplane/Provider BTP investigated for Beta.
2. **Managed database from day one.**

## Decision Outcome

Chosen option: **"Self-managed database for Trial, managed DB for Beta"**,
because a managed database from day one would delay Trial delivery — its
provisioning mechanism is not yet clarified.

- **Trial:** self-managed database as a StatefulSet with a PVC on the ODG
  workload cluster.
- **Beta:** investigate a managed database provisioned via
  Crossplane/Provider BTP.

## Consequences

Positive:

- Trial ships without external dependencies.
- Can use our existing backup extension
  https://github.com/open-component-model/odg-core/blob/master/src/delivery_db_backup.py
  for the trial.

Negative / follow-up:

- Beta requires provisioning and configuration of a managed DB, including
  backup/restore runbooks (e.g., PVC-full scenario for the migration path).
