# ADR-003: Self-Managed Database for Trial, Managed DB Investigated for Beta

- **Status:** To be discussed — Beta decision under investigation
- **Date:** 2025-08-31

## Context

ODG requires a database for persistence. For the Trial phase, speed of
delivery and simplicity matter more than operational maturity. For Beta, a
production-grade database with backup/restore is required.

## Decision

- **Trial:** self-managed database as a StatefulSet with a PVC on the ODG
  workload cluster.
- **Beta:** investigate a managed database provisioned via
  Crossplane/Provider BTP.

## Alternatives Considered

- **Managed database from day one** — rejected for Trial: provisioning
  mechanism (BTP, RDS, HANA) not yet clarified; would delay Trial delivery.

## Consequences

Positive:

- Trial ships without external dependencies.
- Can use our existing backup extensian https://github.com/open-component-model/odg-core/blob/master/src/delivery_db_backup.py for the trial

Negative / follow-up:
- Beta requires provisioning and configuration of a managed DB, including
  backup/restore runbooks (e.g., PVC-full scenario for the migration path).
