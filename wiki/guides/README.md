# Documentation

Architecture guides, operational runbooks, and validation reports for the mini-baas infrastructure.

---

## Architecture and Infrastructure

| Document | Description |
|----------|-------------|
| [Infrastructure Overview](./infrastructure.md) | Service topology, network model, Compose profiles, and startup order |
| [Container Roles](./docker-container-purposes.md) | Purpose of every container in the stack |

## Gateway and Routing

| Document | Description |
|----------|-------------|
| [Kong Gateway Configuration](./kong-gateway-configuration.md) | How to add endpoints, manage routes, and configure plugins |
| [Authentication Flow Through Kong](./kong-database-authentication-integration.md) | End-to-end auth lifecycle — signup, JWT issuance, RLS enforcement |
| [Kong Blocker Analysis](../archive/kong-blocker-analysis.md) | Historical archive of early gateway integration issues |

## API Specification and Validation

| Document | Description |
|----------|-------------|
| [MVP Schema Specification](./mvp-schema-specification.md) | Endpoint contracts, data models, and validation rules for the MVP |
| [MongoDB Service Validation](../archive/mongo-service-validation.md) | Line-by-line audit of mongo-api against the specification |

## Operations and Development

| Document | Description |
|----------|-------------|
| [Docker Best Practices](./docker-best-practices.md) | Operational conventions for building, running, and maintaining containers |
| [Docker Commands Reference](./docker-commands-reference.md) | Quick reference for Make targets and Compose commands |
| [Partner Demo Runbook](../operations/partner-demo-runbook.md) | Step-by-step demo script for the dual data-plane CRUD flow |

## Status and Planning

| Document | Description |
|----------|-------------|
| [Project Status](../archive/project-status-baas-integration-blockers.md) | Current state, gaps, and priorities |
| [Completion Report — March 31](../archive/today-completion-report.md) | Summary of MVP spec freeze and infrastructure validation |
| [Execution Plan — April 1](../archive/tomorrow-execution-plan.md) | MongoDB integration testing steps and coverage |
