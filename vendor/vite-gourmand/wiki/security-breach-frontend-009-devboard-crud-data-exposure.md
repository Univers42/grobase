# Frontend Breach 009: DevBoard CRUD Sensitive Data Exposure

Date: 2026-05-26
Severity: High
Status: Fixed

## Affected Files

- `Back/src/crud/crud.controller.ts`
- `Back/src/crud/crud.service.ts`
- `View/src/components/database/DatabaseService.ts`
- `View/src/components/database/DatabaseViewer.tsx`
- `View/src/components/database/DataTable.tsx`
- `View/src/components/database/DatabaseCards.tsx`
- `View/src/components/database/RecordModal.tsx`
- `View/src/components/admin/AdminMenu.tsx`
- `View/src/components/DevBoard/DevBoardContent.tsx`
- `View/src/components/DevBoard/constants.ts`
- `View/src/portal_dashboard/types.ts`

## Evidence

The DevBoard database UI displayed masked values for sensitive columns such as `password`, but the backend CRUD API still exposed the raw record fields returned by Prisma. The original generic CRUD also had an incomplete role list (`employe` without the normalized `employee` role), no explicit per-table write policy, no backend field allowlist, and no business tables for menu photos or menu-to-dish relations.

## Exploit Scenario

An authenticated staff user with DevBoard access could call the CRUD API directly and retrieve fields that the UI tried to hide. A UI-only mask is not a security boundary: browser devtools, scripts, extensions, or intercepted API responses can still see the raw JSON payload.

## Root Cause

The backend trusted the generic Prisma result too much and delegated sensitive-field protection to presentation code. The CRUD design also assumed simple numeric IDs and did not model composite tables or virtual relations, which made menu management incomplete and encouraged unsafe workarounds.

## Repair

- Replaced the CRUD controller with an explicit table policy layer.
- Added schema metadata for allowed tables, primary keys, read-only fields, and create/update/delete permissions.
- Removed `password` from the exposed `User` schema and blocked writes to sensitive system tables (`User`, `Role`, `Order`) through DevBoard CRUD.
- Added backend output sanitization so non-allowlisted and sensitive fields are stripped before JSON responses are returned.
- Added backend field allowlists for every writable table.
- Added HTTPS validation for media URL fields such as `image_url`, `photo_url`, and `icon_url`.
- Added support for composite-key business tables: `MenuIngredient`, `DishIngredient`, and `DishAllergen`.
- Added a virtual `MenuDish` table so staff can attach and detach dishes from menus through a controlled API instead of direct hidden join-table access.
- Normalized DevBoard CRUD access for `admin` and `employee` roles while keeping `superadmin` supported by the global role guard.
- Connected admin and employee DevBoard menu screens to the real database viewer instead of static demo cards.

## Verification

- Backend unit tests: `39` suites passed, `324` tests passed.
- New CRUD policy tests verify table exposure, sensitive-field sanitization, read-only system tables, HTTPS media URL rejection, menu creation ownership, and `MenuDish` relation creation.
- Live Docker API verification checked every DevBoard table endpoint:
  - `users`, `roles`, `orders`, `menus`, `menu-images`, `menu-dishes`, `dishes`, `ingredients`, `menu-ingredients`, `dish-ingredients`, `dish-allergens`, `diets`, `themes`, `allergens`, `working-hours`.
- Live workflow verification confirmed an employee can create a published menu, create a dish, add a menu photo, attach the dish to the menu, and read the result from public `/api/menus/:id` with `MenuImage` and `Dish` included.
- CSRF verification confirmed writes without `X-CSRF-Token` are blocked with `403`.
- RBAC verification confirmed a client account receives `403` on `/api/crud/schema`.
- Playwright test added in `View/tests/e2e/devboard-menu-crud.spec.ts` and passed against the live Docker backend.

## Residual Risk

The DevBoard remains a powerful staff tool and should stay behind authenticated, role-protected routes. Future schema additions must be added through the CRUD policy allowlist deliberately; no new Prisma model should be exposed automatically without deciding its read/write permissions and sensitive fields.
