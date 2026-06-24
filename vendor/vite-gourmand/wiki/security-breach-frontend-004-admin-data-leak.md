# Frontend Breach 004: Admin Data Exposure in Console and Tooltips

Date: 2026-05-26
Severity: High
Status: Fixed

## Affected Files

- `View/src/components/database/DatabaseService.ts`
- `View/src/components/database/DataTable.tsx`

## Evidence

The admin database service logged schema, counts, records, table creation payloads, and errors directly to the browser console. The data table masked password/hash cells visually, but the cell `title` attribute still contained the raw value.

## Exploit Scenario

An admin shares a screen, exports browser logs, uses a managed browser, or has a compromised extension. Sensitive schema/record values or masked cell raw values can leak outside the application UI.

## Root Cause

Debug logging and tooltip rendering were not treated as data disclosure surfaces.

## Repair

- Dev-gated database debug/error logs behind `import.meta.env.DEV`.
- Broadened sensitive field metadata to include tokens, secrets, and API keys.
- Masked sensitive table values and removed raw sensitive values from `title` attributes.

## Verification

- Production builds must not print database records/schema payloads from `DatabaseService`.
- Sensitive columns should display `••••••••` and have no raw-value tooltip.

## Residual Risk

Authorized admins can still view and mutate database-backed records through permitted UI/API paths. Backend RBAC and audit logs must enforce the real boundary.