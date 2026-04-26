# Documentation

Architecture guides, operational runbooks, and validation reports for the mini-baas infrastructure.

---

## Architecture and Infrastructure

| Document                                                              | Description                                                              |
| --------------------------------------------------------------------- | ------------------------------------------------------------------------ |
| [Infrastructure Overview](Insfrastructure.md)                         | Service topology, network model, Compose profiles, and startup order     |
| [Container Roles](Docker-Container-Purposes.md)                       | Purpose of every container in the stack                                  |
| [Production BaaS Architecture](Production-BaaS-Architecture.md)       | Production-grade gateway-only microservices architecture and reuse model |
| [Production Performance Strategy](Production-Performance-Strategy.md) | Cache, routing, failover, observability, versioning, and Trino rules     |
| [Fly Deployment](Fly-Deployment.md)                                   | Multi-app Fly.io deployment strategy, secrets, status, and smoke testing |

## Gateway and Routing

| Document                                                                        | Description                                                       |
| ------------------------------------------------------------------------------- | ----------------------------------------------------------------- |
| [Kong Gateway Configuration](Kong-Gateway-Configuration.md)                     | How to add endpoints, manage routes, and configure plugins        |
| [Authentication Flow Through Kong](Kong-Database-Authentication-Integration.md) | End-to-end auth lifecycle — signup, JWT issuance, RLS enforcement |
| [Kong Blocker Analysis](kong-blocker-analysis.md)                               | Historical archive of early gateway integration issues            |

## API Specification and Validation

| Document                                                        | Description                                                       |
| --------------------------------------------------------------- | ----------------------------------------------------------------- |
| [MVP Schema Specification](MVP-Schema-Specification.md)         | Endpoint contracts, data models, and validation rules for the MVP |
| [MongoDB Service Validation](Mongo-Service-Validation.md)       | Line-by-line audit of mongo-api against the specification         |
| [SDK v2 Design](SDK-v2-Design.md)                               | Product SDK architecture, layering, auth/session strategy         |
| [SDK Backend Service Coverage](SDK-Backend-Service-Coverage.md) | Docker/Fly service coverage matrix for the SDK                    |
| [JavaScript SDK](../packages/mini-baas-sdk/README.md)           | `@mini-baas/js` product SDK for external applications             |

## Operations and Development

| Document                                                  | Description                                                               |
| --------------------------------------------------------- | ------------------------------------------------------------------------- |
| [Docker Best Practices](Docker-Best-Practices.md)         | Operational conventions for building, running, and maintaining containers |
| [Docker Commands Reference](Docker-Commands-Reference.md) | Quick reference for Make targets and Compose commands                     |
| [Partner Demo Runbook](Partner-Demo-Runbook.md)           | Step-by-step demo script for the dual data-plane CRUD flow                |

## Status and Planning

| Document                                                      | Description                                              |
| ------------------------------------------------------------- | -------------------------------------------------------- |
| [Project Status](Project-Status-BaaS-Integration-Blockers.md) | Current state, gaps, and priorities                      |
| [Completion Report — March 31](TODAY-COMPLETION-REPORT.md)    | Summary of MVP spec freeze and infrastructure validation |
| [Execution Plan — April 1](TOMORROW-EXECUTION-PLAN.md)        | MongoDB integration testing steps and coverage           |
