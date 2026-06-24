# Vite Gourmand — Diagramme entité-association complet

> Cartographie exhaustive du schéma relationnel PostgreSQL (Prisma).
> 46 modèles couvrant identité, catalogue, commande, fidélité, marketing, support, opérations, RGPD.

Le schéma est volumineux, donc cette page propose **deux niveaux de lecture** :

1. **Vue complète** — toutes les entités et toutes les relations, sur un seul diagramme.
2. **Vues par domaine** — versions allégées, regroupées par responsabilité métier (utiles pour comprendre un sous-système à la fois).

---

## 1. Vue complète (toutes les entités)

```mermaid
erDiagram
    %% ===== IDENTITY & ACCESS =====
    User ||--o{ Role : "role_id"
    Role ||--o{ RolePermission : "role_id"
    Permission ||--o{ RolePermission : "permission_id"
    User ||--o{ UserSession : "user_id"
    User ||--o{ PasswordResetToken : "user_id"
    User ||--o{ UserAddress : "user_id"
    User ||--o{ UserConsent : "user_id"

    %% ===== CATALOG =====
    Menu ||--o{ MenuImage : "menu_id"
    Menu ||--o{ MenuIngredient : "menu_id"
    Menu }o--|| Diet : "diet_id"
    Menu }o--|| Theme : "theme_id"
    Menu }o--|| User : "created_by"
    Dish ||--o{ DishAllergen : "dish_id"
    Dish ||--o{ DishIngredient : "dish_id"
    Menu }o--o{ Dish : "MenuDishes"
    Allergen ||--o{ DishAllergen : "allergen_id"
    Ingredient ||--o{ DishIngredient : "ingredient_id"
    Ingredient ||--o{ MenuIngredient : "ingredient_id"

    %% ===== ORDER LIFECYCLE =====
    User ||--o{ Order : "user_id"
    Order ||--o{ OrderMenu : "order_id"
    Menu ||--o{ OrderMenu : "menu_id"
    Order ||--o{ OrderOrderTag : "order_id"
    OrderTag ||--o{ OrderOrderTag : "tag_id"
    OrderTag }o--|| User : "created_by"
    Order ||--o{ OrderStatusHistory : "order_id"
    Order ||--o{ DeliveryAssignment : "order_id"
    DeliveryAssignment }o--|| User : "delivery_person_id"
    Order }o--|| Discount : "discount_id"
    Discount }o--|| User : "created_by"

    %% ===== LOYALTY =====
    User ||--|| LoyaltyAccount : "user_id"
    LoyaltyAccount ||--o{ LoyaltyTransaction : "loyalty_account_id"
    Order ||--o{ LoyaltyTransaction : "order_id"

    %% ===== MARKETING =====
    Promotion }o--|| Discount : "discount_id"
    Promotion }o--|| User : "created_by"
    User ||--o{ UserPromotion : "user_id"
    Promotion ||--o{ UserPromotion : "promotion_id"
    NewsletterSubscriber }o--|| User : "user_id (nullable)"
    NewsletterSendLog }o--|| Promotion : "promotion_id"

    %% ===== REVIEWS =====
    User ||--o{ Publish : "user_id"
    User ||--o{ Publish : "moderated_by"
    Order ||--o{ Publish : "order_id"
    Publish ||--o{ ReviewImage : "review_id"

    %% ===== SUPPORT & MESSAGING =====
    User ||--o{ SupportTicket : "created_by"
    User ||--o{ SupportTicket : "assigned_to"
    SupportTicket ||--o{ TicketMessage : "ticket_id"
    User ||--o{ TicketMessage : "user_id"
    User ||--o{ Message : "sender_id"
    User ||--o{ Message : "recipient_id"
    Message ||--o{ Message : "parent_id (thread)"
    User ||--o{ Notification : "user_id"

    %% ===== OPERATIONS =====
    Company ||--o{ CompanyOwner : "company_id"
    User ||--o{ CompanyOwner : "user_id"
    Company ||--o{ CompanyWorkingHours : "company_id"
    WorkingHours ||--o{ CompanyWorkingHours : "working_hours_id"
    Company ||--o{ Event : "company_id"
    User ||--o{ KanbanColumn : "created_by"
    User ||--o{ TimeOffRequest : "user_id"
    User ||--o{ TimeOffRequest : "decided_by"

    %% ===== GDPR / AUDIT =====
    User ||--o{ DataDeletionRequest : "user_id"
    User ||--o{ DataDeletionRequest : "processed_by"
    ContactMessage }o--|| User : "(anonyme)"
```

---

## 2. Vue par domaine

### 2.1 Identité, sessions, sécurité

```mermaid
erDiagram
    User {
        int id PK
        string email UK
        string password
        string first_name
        string last_name
        string phone_number
        int role_id FK
        bool is_active
        bool is_email_verified
        bool is_deleted
        datetime last_login_at
        bool gdpr_consent
        datetime gdpr_consent_date
        bool marketing_consent
        bool newsletter_consent
    }
    Role {
        int id PK
        string name UK
        string description
    }
    Permission {
        int id PK
        string name UK
        string resource
        string action
    }
    RolePermission {
        int role_id PK,FK
        int permission_id PK,FK
    }
    UserSession {
        int id PK
        int user_id FK
        string session_token UK
        string ip_address
        string user_agent
        datetime expires_at
        bool is_active
    }
    PasswordResetToken {
        int id PK
        string token UK
        int user_id FK
        datetime expires_at
        bool used
    }
    UserAddress {
        int id PK
        int user_id FK
        string label
        string street_address
        string city
        string postal_code
        decimal latitude
        decimal longitude
        bool is_default
    }
    UserConsent {
        int id PK
        int user_id FK
        string consent_type
        bool is_granted
        datetime granted_at
        datetime revoked_at
        string ip_address
    }

    Role ||--o{ User : "1 role → N users"
    Role ||--o{ RolePermission : "M:N permissions"
    Permission ||--o{ RolePermission : ""
    User ||--o{ UserSession : "JWT sessions"
    User ||--o{ PasswordResetToken : "reset flow"
    User ||--o{ UserAddress : "addresses"
    User ||--o{ UserConsent : "RGPD log"
```

### 2.2 Catalogue : menus, plats, allergènes, ingrédients

```mermaid
erDiagram
    Menu {
        int id PK
        string title
        text description
        text conditions
        int person_min
        decimal price_per_person
        int remaining_qty
        string status
        int diet_id FK
        int theme_id FK
        int created_by FK
        bool is_seasonal
        date available_from
        date available_until
        datetime published_at
    }
    Dish {
        int id PK
        string title
        text description
        string photo_url
        string course_type
    }
    Diet {
        int id PK
        string name UK
        string description
        string icon_url
    }
    Theme {
        int id PK
        string name UK
        string description
        string icon_url
    }
    Allergen {
        int id PK
        string name UK
        string icon_url
    }
    Ingredient {
        int id PK
        string name UK
        string unit
        decimal current_stock
        decimal min_stock_level
        decimal cost_per_unit
        datetime last_restocked_at
    }
    MenuImage {
        int id PK
        int menu_id FK
        string image_url
        string alt_text
        int display_order
        bool is_primary
    }
    MenuIngredient {
        int menu_id PK,FK
        int ingredient_id PK,FK
        decimal quantity_per_person
    }
    DishAllergen {
        int dish_id PK,FK
        int allergen_id PK,FK
    }
    DishIngredient {
        int dish_id PK,FK
        int ingredient_id PK,FK
        decimal quantity
    }

    Diet ||--o{ Menu : "1 régime → N menus"
    Theme ||--o{ Menu : "1 thème → N menus"
    Menu ||--o{ MenuImage : "galerie"
    Menu }o--o{ Dish : "MenuDishes (M:N)"
    Dish ||--o{ DishAllergen : ""
    Allergen ||--o{ DishAllergen : "14 allergènes UE"
    Dish ||--o{ DishIngredient : ""
    Ingredient ||--o{ DishIngredient : ""
    Menu ||--o{ MenuIngredient : ""
    Ingredient ||--o{ MenuIngredient : ""
```

### 2.3 Commande, livraison, statuts

```mermaid
erDiagram
    Order {
        int id PK
        string order_number UK
        int user_id FK
        date delivery_date
        string delivery_hour
        text delivery_address
        string delivery_city
        decimal delivery_distance_km
        int person_number
        decimal menu_price
        decimal delivery_price
        int discount_id FK
        decimal discount_percent
        decimal discount_amount
        decimal total_price
        string status
        bool material_lending
        bool material_returned
        datetime material_return_deadline
        text cancellation_reason
        string cancellation_contact_mode
        text special_instructions
        datetime confirmed_at
        datetime delivered_at
        datetime cancelled_at
    }
    OrderMenu {
        int order_id PK,FK
        int menu_id PK,FK
        int quantity
    }
    OrderStatusHistory {
        int id PK
        int order_id FK
        string old_status
        string new_status
        text notes
        datetime changed_at
    }
    DeliveryAssignment {
        int id PK
        int order_id FK
        int delivery_person_id FK
        string vehicle_type
        string status
        datetime assigned_at
        datetime picked_up_at
        datetime delivered_at
        text delivery_notes
        string proof_photo_url
        int client_rating
    }
    OrderTag {
        int id PK
        string label UK
        string color
        int created_by FK
    }
    OrderOrderTag {
        int order_id PK,FK
        int tag_id PK,FK
    }
    Discount {
        int id PK
        string code UK
        string type
        decimal value
        decimal min_order_amount
        int max_uses
        int current_uses
        date valid_from
        date valid_until
        bool is_active
    }

    Order ||--o{ OrderMenu : "panier"
    Order ||--o{ OrderStatusHistory : "audit statut"
    Order ||--o{ DeliveryAssignment : "livraison"
    Order ||--o{ OrderOrderTag : ""
    OrderTag ||--o{ OrderOrderTag : "tags admin"
    Discount ||--o{ Order : "code promo"
```

### 2.4 Fidélité & marketing

```mermaid
erDiagram
    LoyaltyAccount {
        int id PK
        int user_id UK,FK
        int total_earned
        int total_spent
        int balance
        datetime last_activity_at
    }
    LoyaltyTransaction {
        int id PK
        int loyalty_account_id FK
        int order_id FK
        int points
        string type
        text description
    }
    Promotion {
        int id PK
        string title
        text description
        string type
        string image_url
        int discount_id FK
        int priority
        bool is_active
        bool is_public
        datetime start_date
        datetime end_date
        int created_by FK
    }
    UserPromotion {
        int id PK
        int user_id FK
        int promotion_id FK
        bool is_seen
        bool is_used
        datetime used_at
    }
    NewsletterSubscriber {
        int id PK
        string email UK
        int user_id FK
        string first_name
        bool is_active
        string token UK
        datetime confirmed_at
        datetime unsubscribed_at
    }
    NewsletterSendLog {
        int id PK
        int promotion_id FK
        int recipients_count
        datetime sent_at
        int sent_by FK
        string status
    }
    ContactMessage {
        int id PK
        string title
        text description
        string email
        datetime created_at
    }

    LoyaltyAccount ||--o{ LoyaltyTransaction : ""
    Promotion ||--o{ UserPromotion : "ciblage"
    Promotion ||--o{ NewsletterSendLog : ""
```

### 2.5 Avis, support, messagerie

```mermaid
erDiagram
    Publish {
        int id PK
        int user_id FK
        int order_id FK
        smallint note
        text description
        string status
        int moderated_by FK
        datetime moderated_at
    }
    ReviewImage {
        int id PK
        int review_id FK
        string image_url
        datetime uploaded_at
    }
    SupportTicket {
        int id PK
        string ticket_number UK
        int created_by FK
        int assigned_to FK
        string category
        string priority
        string status
        string subject
        text description
        datetime resolved_at
        datetime closed_at
    }
    TicketMessage {
        int id PK
        int ticket_id FK
        int user_id FK
        text body
        bool is_internal
    }
    Message {
        int id PK
        int sender_id FK
        int recipient_id FK
        string subject
        text body
        string priority
        bool is_read
        datetime sent_at
        datetime read_at
        int parent_id FK
    }
    Notification {
        int id PK
        int user_id FK
        string type
        string title
        text body
        string link_url
        bool is_read
        datetime read_at
    }

    Publish ||--o{ ReviewImage : "galerie"
    SupportTicket ||--o{ TicketMessage : "fil de discussion"
    Message ||--o{ Message : "threads (parent_id)"
```

### 2.6 Opérations : société, horaires, événements, RH, RGPD

```mermaid
erDiagram
    Company {
        int id PK
        string name
        string slogan
        text description
        date first_opening_date
        text address
        string city
        string postal_code
        string country
        string phone
        string email
        string website
        string siret UK
        string logo_url
        bool is_active
    }
    CompanyOwner {
        int company_id PK,FK
        int user_id PK,FK
        string role
        bool is_primary
    }
    WorkingHours {
        int id PK
        string day UK
        string opening
        string closing
    }
    CompanyWorkingHours {
        int company_id PK,FK
        int working_hours_id PK,FK
    }
    Event {
        int id PK
        int company_id FK
        string name
        string event_type
        int guest_count
        date event_date
        string location
        bool is_public
    }
    KanbanColumn {
        int id PK
        string name
        string mapped_status
        string color
        int position
        bool is_active
        int created_by FK
    }
    TimeOffRequest {
        int id PK
        int user_id FK
        date start_date
        date end_date
        string type
        string status
        text reason
        int decided_by FK
        datetime decided_at
    }
    DataDeletionRequest {
        int id PK
        int user_id FK
        text reason
        string status
        datetime requested_at
        datetime processed_at
        int processed_by FK
    }

    Company ||--o{ CompanyOwner : "owners"
    Company ||--o{ CompanyWorkingHours : ""
    WorkingHours ||--o{ CompanyWorkingHours : "lundi → dimanche"
    Company ||--o{ Event : "événements"
```

---

## 3. Cardinalités & règles métier importantes

| Relation | Cardinalité | Règle |
|---|:---:|---|
| `User.role_id → Role` | 1..N | Un utilisateur a un seul rôle ; un rôle s'applique à plusieurs utilisateurs |
| `Role ↔ Permission` | M:N | Via `RolePermission` (RBAC) |
| `Menu ↔ Dish` | M:N | Un plat appartient à plusieurs menus, un menu contient plusieurs plats (`MenuDishes`) |
| `Dish ↔ Allergen` | M:N | 14 allergènes UE déclarés via `DishAllergen` |
| `Order → OrderMenu → Menu` | 1..N..1 | Une commande agrège plusieurs menus avec quantités |
| `Order → OrderStatusHistory` | 1..N | Chaque transition de statut est journalisée (auditable) |
| `User ↔ LoyaltyAccount` | 1:1 | Un compte fidélité unique par utilisateur (`user_id UNIQUE`) |
| `Order → Publish` | 1..N | Un avis est rattaché à une commande livrée |
| `Publish.moderated_by` | N..1 | L'admin qui modère est tracé |
| `Promotion → UserPromotion` | 1..N | Ciblage individuel : `(user_id, promotion_id) UNIQUE` |
| `Company ↔ WorkingHours` | M:N | Une société peut afficher 7 lignes horaires (lundi → dimanche) |
| `Message.parent_id` | N..1 | Auto-référence permettant les fils de discussion |

---

## 4. Conventions Prisma observées

- **PK auto-incrémentées** : `Int @id @default(autoincrement())` pour toutes les entités principales.
- **PK composées** : tables de jonction utilisent `@@id([col1, col2])` (`OrderMenu`, `DishAllergen`, `MenuIngredient`, `RolePermission`, `CompanyWorkingHours`, `OrderOrderTag`, `UserPromotion`).
- **Soft delete** : `User.is_deleted` + `User.deleted_at` (RGPD-compatible).
- **Timestamps** : `created_at` / `updated_at` en `Timestamptz(6)` pour préserver le fuseau horaire.
- **Audit** : `OrderStatusHistory`, `UserConsent`, `DataDeletionRequest` enregistrent qui/quand/quoi.
- **Index stratégiques** : `idx_order_user_date`, `idx_menu_status`, `idx_promotion_public` (index partiels sur lignes actives), `idx_session_token`.
- **Cascades** : `onDelete: Cascade` pour les enfants logiques (OrderMenu, DishAllergen, MenuImage, ReviewImage), `NoAction` pour les références "auteur" (préserver l'historique même si l'auteur est supprimé).
