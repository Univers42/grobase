# Schema DDL for JWT / legacy-header users

Declined 2026-10-29 (devil G1g, [ADR 0009](../docs/adr/0009-query-router-ddl-requires-api-key-write-scope.md)).

## Why

Every measured DDL caller is an app key. These callers send `X-Baas-Api-Key`:
- the osionos bridge;
- the seed scripts;
- the verify scripts;
- the postman corpus.

For a user, the only rule that is cheap to check is "own tenant" (`tenantId === userId`). It is always
true behind Kong, and a forger on the docker network can make it true. The PDP has no `ddl` action that
could rule per role instead.

## What would change this

A measured JWT or legacy-header DDL caller, **and** G1a's signed-envelope enforcement live, so that a
user identity can no longer be forged on the internal network.
