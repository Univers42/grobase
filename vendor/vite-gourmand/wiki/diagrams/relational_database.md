# PostgreSQL — Relational Database Schema

> **Purpose:** All transactional, ACID-compliant data — users, orders, menus, reviews, messaging, loyalty, GDPR compliance.
> Analytics, activity logs, and search tracking live in [MongoDB](./nosql_database.md).

---

## Design Principles

| Principle | Implementation |
|-----------|---------------|
| **Normalization** | Each entity in its own table; junction tables for M:N |
| **Referential Integrity** | Foreign keys with `ON DELETE CASCADE` or `SET NULL` |
| **Soft Deletion** | `is_active` flag on User (subject: disable employee accounts) |
| **Audit Trail** | `created_at`, `updated_at` on mutable tables; `OrderStatusHistory` |
| **GDPR by Design** | Consent tracking, data export, anonymization support |
| **Index Strategy** | Composite indexes on frequent query patterns |
| **Prepared Statements** | All queries parameterized (Prisma handles this) |

---

## Subject-Specific Business Rules

| Rule (from subject) | DB Implementation |
|---------------------|-------------------|
| Dishes shared across menus | M:N junction `MenuDishes` (no FK on Dish) |
| 14 EU allergens per dish | M:N junction `DishAllergens` |
| Menu conditions (lead time, storage) | `Menu.conditions` text field |
| 10% discount if `person_number >= person_min + 5` | `Order.discount_percent`, `Order.discount_amount` computed at creation |
| Delivery: €5 + €0.59/km if outside Bordeaux | `Order.delivery_city`, `Order.delivery_distance_km`, `Order.delivery_price` |
| Client can cancel/modify only before `accepted` | Backend guard on `Order.status` |
| Employee must specify contact mode + reason to cancel | `Order.cancellation_reason`, `Order.cancellation_contact_mode` |
| Material return: 10 business days, €600 penalty | `Order.material_return_deadline` set on status `awaiting_material_return` |
| Review linked to order, note 1-5 | `Publish.orderId` FK, `Publish.note` |
| Review moderation by employee/admin | `Publish.status` (pending/approved/rejected) |
| Admin account seeded, no admin creation from app | Seed script creates José's account |
| Admin can disable employee accounts | `User.is_active` flag |
| Contact form: title + description + email | `ContactMessage` table, triggers email |
| Working hours Mon-Sun in footer | `WorkingHours` table |
| Admin charts: orders per menu from NoSQL | MongoDB `MenuAnalytics` collection |
| Admin: chiffre d'affaires par menu with filters | MongoDB `RevenueByMenu` collection |
| **Stock management via ingredients** | **`Ingredient.current_stock`, `DishIngredient` junction tracks quantities** |
| **Menu stock calculation** | **Backend: sum ingredient needs × person_min, compare to `Ingredient.current_stock`** |
| **Dish stock calculation** | **Backend: for each ingredient in dish, `current_stock / quantity` = max servings** |

---

## Subject Order Statuses

| Status Key | French Label (subject) | Triggered By |
|------------|----------------------|--------------|
| `pending` | En attente | Client places order |
| `accepted` | Accepté | Employee validates |
| `preparing` | En préparation | Kitchen starts |
| `delivering` | En cours de livraison | Delivery starts |
| `delivered` | Livré | Delivery confirms |
| `awaiting_material_return` | En attente du retour de matériel | If `material_lending = true` |
| `completed` | Terminée | Delivered (no material) or material returned |
| `cancelled` | Annulée | Client (pre-accepted) or Employee (with reason) |

---

## Entity-Relationship Diagram

```mermaid
erDiagram

    %% ========================================
    %% AUTHENTICATION & AUTHORIZATION
    %% ========================================

    User {
        int id PK "SERIAL"
        string email UK "Indexed, login identifier"
        string password_hash "Bcrypt, min 12 rounds"
        string first_name "NOT NULL"
        string last_name
        string phone_number
        string city
        string country
        string postal_code
        int role_id FK "NOT NULL"
        boolean is_active "DEFAULT true"
        boolean is_email_verified "DEFAULT false"
        boolean is_deleted "Soft delete flag"
        datetime deleted_at
        string preferred_language "DEFAULT fr"
        datetime created_at "DEFAULT now()"
        datetime updated_at "Auto-updated"
        datetime last_login_at
    }

    Role {
        int id PK "SERIAL"
        string name UK "admin, employee, utilisateur"
        string description
        datetime created_at
    }

    Permission {
        int id PK "SERIAL"
        string name UK "e.g. manage_orders"
        string resource "orders, menus, users, reviews"
        string action "create, read, update, delete"
    }

    RolePermission {
        int role_id FK
        int permission_id FK
    }

    UserAddress {
        int id PK "SERIAL"
        int user_id FK "ON DELETE CASCADE"
        string label "Home, Work, Other"
        string street_address "NOT NULL"
        string city "NOT NULL"
        string postal_code "NOT NULL"
        string country "NOT NULL"
        float latitude "For delivery optimization"
        float longitude
        boolean is_default "DEFAULT false"
        datetime created_at
    }

    PasswordResetToken {
        int id PK "SERIAL"
        string token UK "Hashed"
        int user_id FK "ON DELETE CASCADE"
        datetime expires_at
        boolean used "DEFAULT false"
        datetime created_at
    }

    UserSession {
        int id PK "SERIAL"
        int user_id FK "ON DELETE CASCADE"
        string session_token UK
        string ip_address
        string user_agent
        datetime created_at
        datetime expires_at
        boolean is_active "DEFAULT true"
    }

    %% ========================================
    %% GDPR & CONSENT
    %% ========================================

    UserConsent {
        int id PK "SERIAL"
        int user_id FK "ON DELETE CASCADE"
        string consent_type "marketing, analytics, cookies"
        boolean is_granted
        datetime granted_at
        datetime revoked_at
        string ip_address "Proof of consent"
    }

    DataDeletionRequest {
        int id PK "SERIAL"
        int user_id FK "ON DELETE SET NULL"
        string reason
        string status "pending, approved, completed, rejected"
        datetime requested_at "DEFAULT now()"
        datetime processed_at
        int processed_by FK "Admin who handled it"
    }

    %% ========================================
    %% MENU MANAGEMENT
    %% ========================================

    Menu {
        int id PK "SERIAL"
        string title "NOT NULL, indexed"
        text description
        text conditions "Lead time, storage, etc."
        int person_min "CHECK > 0"
        decimal price_per_person "DECIMAL 10 2"
        int remaining_qty "CHECK >= 0, stock"
        string status "draft, published, archived"
        int diet_id FK
        int theme_id FK
        int created_by FK "User who created it"
        boolean is_seasonal "DEFAULT false"
        date available_from
        date available_until
        datetime created_at
        datetime updated_at
        datetime published_at
    }

    MenuImage {
        int id PK "SERIAL"
        int menu_id FK "ON DELETE CASCADE"
        string image_url "NOT NULL"
        string alt_text
        int display_order "DEFAULT 0"
        boolean is_primary "DEFAULT false"
        datetime uploaded_at
    }

    Diet {
        int id PK "SERIAL"
        string name UK "Classique, Vegetarien, Vegan, etc."
        string description
        string icon_url
    }

    Theme {
        int id PK "SERIAL"
        string name UK "Noel, Paques, Classique, Evenement"
        string description
        string icon_url
    }

    Dish {
        int id PK "SERIAL"
        string title "NOT NULL"
        text description
        string photo_url
        string course_type "entree, plat, dessert"
        datetime created_at
    }

    MenuDish {
        int menu_id FK "ON DELETE CASCADE"
        int dish_id FK "ON DELETE CASCADE"
    }

    Allergen {
        int id PK "SERIAL"
        string name UK "14 EU allergens"
        string icon_url
    }

    DishAllergen {
        int dish_id FK "ON DELETE CASCADE"
        int allergen_id FK "ON DELETE CASCADE"
    }

    Ingredient {
        int id PK "SERIAL"
        string name UK "NOT NULL"
        string unit "kg, litres, pieces, DEFAULT kg"
        decimal current_stock "DECIMAL 10 2, DEFAULT 0"
        decimal min_stock_level "DECIMAL 10 2, alert threshold"
        decimal cost_per_unit "DECIMAL 10 2"
        datetime last_restocked_at "Nullable"
        datetime created_at "DEFAULT now()"
        datetime updated_at "Auto-updated"
    }

    DishIngredient {
        int dish_id FK "ON DELETE CASCADE"
        int ingredient_id FK "ON DELETE CASCADE"
        decimal quantity "DECIMAL 10 3, per serving"
    }

    MenuIngredient {
        int menu_id FK "ON DELETE CASCADE"
        int ingredient_id FK "ON DELETE CASCADE"
        decimal quantity_per_person "DECIMAL 10 3"
    }

    %% ========================================
    %% ORDER LIFECYCLE
    %% ========================================

    Order {
        int id PK "SERIAL"
        string order_number UK "ORD-YYYY-NNNNN"
        int user_id FK "Client who placed it"
        datetime order_date "DEFAULT now()"
        date delivery_date "NOT NULL, prestation date"
        string delivery_hour
        string delivery_address
        string delivery_city "DEFAULT Bordeaux"
        float delivery_distance_km "DEFAULT 0"
        int person_number "CHECK >= menu.person_min"
        decimal menu_price "DECIMAL 10 2"
        decimal delivery_price "DECIMAL 10 2"
        decimal discount_percent "DEFAULT 0"
        decimal discount_amount "DEFAULT 0"
        decimal total_price "DECIMAL 10 2"
        string status "see status table above"
        boolean material_lending "DEFAULT false"
        boolean material_returned "DEFAULT false"
        datetime material_return_deadline
        string cancellation_reason "Required if cancelled by employee"
        string cancellation_contact_mode "gsm, email"
        text special_instructions
        datetime confirmed_at
        datetime delivered_at
        datetime cancelled_at
        datetime created_at
        datetime updated_at
    }

    OrderStatusHistory {
        int id PK "SERIAL"
        int order_id FK "ON DELETE CASCADE"
        string old_status
        string new_status "NOT NULL"
        string notes
        datetime changed_at "DEFAULT now()"
    }

    %% ========================================
    %% REVIEWS (Publish model)
    %% ========================================

    Publish {
        int id PK "SERIAL"
        string note "Rating 1-5"
        string description "Comment text"
        string status "pending, approved, rejected"
        int user_id FK "ON DELETE CASCADE"
        int order_id FK "ON DELETE SET NULL"
        datetime created_at
    }

    %% ========================================
    %% CONTACT
    %% ========================================

    ContactMessage {
        int id PK "SERIAL"
        string title "NOT NULL"
        text description "NOT NULL"
        string email "NOT NULL"
        datetime created_at "DEFAULT now()"
    }

    %% ========================================
    %% COMPANY SCHEDULE
    %% ========================================

    WorkingHours {
        int id PK "SERIAL"
        string day "Lundi to Dimanche"
        string opening
        string closing
    }

    %% ========================================
    %% LOYALTY & PROMOTIONS
    %% ========================================

    LoyaltyAccount {
        int id PK "SERIAL"
        int user_id FK "ON DELETE CASCADE"
        int total_earned
        int total_spent
        int balance "earned minus spent"
        datetime last_activity_at
    }

    LoyaltyTransaction {
        int id PK "SERIAL"
        int loyalty_account_id FK "ON DELETE CASCADE"
        int order_id FK "ON DELETE SET NULL"
        int points "Positive earn Negative spend"
        string type "earn, redeem, expire, bonus"
        text description
        datetime created_at
    }

    Discount {
        int id PK "SERIAL"
        string code UK "Promo code"
        string description
        string type "percentage, fixed_amount"
        decimal value "DECIMAL 10 2"
        decimal min_order_amount "DECIMAL 10 2"
        int max_uses "NULL unlimited"
        int current_uses "DEFAULT 0"
        date valid_from
        date valid_until
        boolean is_active "DEFAULT true"
        int created_by FK "Admin who created it"
    }

    %% ========================================
    %% EMPLOYEE MANAGEMENT
    %% ========================================

    TimeOffRequest {
        int id PK "SERIAL"
        int user_id FK "ON DELETE CASCADE"
        date start_date
        date end_date
        string type "vacation, sick, personal"
        string status "pending, approved, rejected"
        text reason
        int decided_by FK "Admin"
        datetime requested_at "DEFAULT now()"
        datetime decided_at
    }

    %% ========================================
    %% MESSAGING & SUPPORT
    %% ========================================

    Message {
        int id PK "SERIAL"
        int sender_id FK "ON DELETE SET NULL"
        int recipient_id FK "ON DELETE SET NULL"
        string subject
        text body "NOT NULL"
        string priority "low, normal, high, urgent"
        boolean is_read "DEFAULT false"
        datetime sent_at "DEFAULT now()"
        datetime read_at
        int parent_id FK "Thread reply"
    }

    Notification {
        int id PK "SERIAL"
        int user_id FK "ON DELETE CASCADE"
        string type "order_update, promo, system, review"
        string title
        text body
        string link_url
        boolean is_read "DEFAULT false"
        datetime created_at "DEFAULT now()"
        datetime read_at
    }

    SupportTicket {
        int id PK "SERIAL"
        string ticket_number UK "TKT-YYYY-NNNNN"
        int created_by FK "ON DELETE SET NULL"
        int assigned_to FK "ON DELETE SET NULL"
        string category "order, payment, account, other"
        string priority "low, normal, high, urgent"
        string status "open, in_progress, waiting, resolved, closed"
        string subject "NOT NULL"
        text description
        datetime created_at "DEFAULT now()"
        datetime resolved_at
        datetime closed_at
    }

    TicketMessage {
        int id PK "SERIAL"
        int ticket_id FK "ON DELETE CASCADE"
        int user_id FK "ON DELETE SET NULL"
        text body "NOT NULL"
        boolean is_internal "Staff-only note"
        datetime created_at "DEFAULT now()"
    }

    %% ========================================
    %% KANBAN CONFIGURATION
    %% ========================================

    KanbanColumn {
        int id PK "SERIAL"
        string name "NOT NULL"
        string mapped_status "Order status it represents"
        string color "Hex color"
        int position "Display order"
        boolean is_active "DEFAULT true"
        int created_by FK
        datetime created_at
    }

    OrderTag {
        int id PK "SERIAL"
        string label UK "urgent, vip, fragile, etc."
        string color "Hex color"
        int created_by FK
    }

    OrderOrderTag {
        int order_id FK "ON DELETE CASCADE"
        int tag_id FK "ON DELETE CASCADE"
    }

    %% ========================================
    %% RELATIONSHIPS
    %% ========================================

    %% Auth & Users
    Role ||--o{ User : "has"
    Role ||--o{ RolePermission : "grants"
    Permission ||--o{ RolePermission : "assigned_via"
    User ||--o{ UserAddress : "has"
    User ||--o{ UserSession : "has"
    User ||--o{ PasswordResetToken : "requests"
    User ||--o{ UserConsent : "gives"
    User ||--o{ DataDeletionRequest : "requests"

    %% Menus (M:N with Dish via MenuDish)
    Diet ||--o{ Menu : "categorizes"
    Theme ||--o{ Menu : "categorizes"
    User ||--o{ Menu : "creates"
    Menu ||--o{ MenuImage : "has"
    Menu ||--o{ MenuDish : "includes"
    Dish ||--o{ MenuDish : "appears_in"
    Menu ||--o{ MenuIngredient : "requires"
    Ingredient ||--o{ MenuIngredient : "used_in"
    Dish ||--o{ DishIngredient : "requires"
    Ingredient ||--o{ DishIngredient : "used_in"
    Dish ||--o{ DishAllergen : "has"
    Allergen ||--o{ DishAllergen : "flags"

    %% Orders
    User ||--o{ Order : "places"
    Order ||--o{ OrderStatusHistory : "tracked_by"
    Order ||--o{ OrderOrderTag : "tagged_with"
    OrderTag ||--o{ OrderOrderTag : "applied_to"

    %% Reviews
    User ||--o{ Publish : "writes"
    Order ||--o{ Publish : "reviewed_via"

    %% Loyalty
    User ||--o{ LoyaltyAccount : "has"
    LoyaltyAccount ||--o{ LoyaltyTransaction : "records"
    Order ||--o{ LoyaltyTransaction : "triggers"
    User ||--o{ Discount : "creates admin"

    %% Employee
    User ||--o{ TimeOffRequest : "requests"
    User ||--o{ TimeOffRequest : "decides admin"

    %% Messaging
    User ||--o{ Message : "sends"
    User ||--o{ Message : "receives"
    User ||--o{ Notification : "notified"
    User ||--o{ SupportTicket : "creates"
    User ||--o{ SupportTicket : "assigned_to"
    SupportTicket ||--o{ TicketMessage : "has"
    User ||--o{ TicketMessage : "writes"

    %% Kanban
    User ||--o{ KanbanColumn : "configures"
    User ||--o{ OrderTag : "creates"