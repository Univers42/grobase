# Use Cases by Role

> Based on the Studi subject requirements. Items marked 🌟 are bonus features beyond the subject scope.

### 🟠 Admin User (José)

**Subject: "Il doit en plus, être capable de faire tout ce qu'un employé peut faire"**

- [ ] **Employee Account Management**
  - Create employee accounts (email + password)
  - Employee receives email notification (password NOT in email)
  - Disable employee accounts (`is_active = false`)
  - Cannot create admin accounts from the application

- [ ] **Menu Management** (same as employee, see below)

- [ ] **Order Management** (same as employee, see below)

- [ ] **Review Moderation** (same as employee, see below)

- [ ] **Analytics & Charts** (admin-only)
  - View number of orders per menu via chart (data from MongoDB)
  - Compare menus against each other via graph
  - View chiffre d'affaires (revenue) per menu with filters:
    - Filter by specific menu
    - Filter by date range (duration)

---

### 🟡 Employee User

**Subject: "Il peut modifier / supprimer les menus, plats, et les horaires"**

- [ ] **Menu & Dish Management**
  - Create, update, and delete menus (title, description, conditions, images, etc.)
  - Create, update, and delete dishes (with allergen associations)
  - Assign dishes to menus (M:N relationship)
  - Update company working hours
  - **Manage ingredients (add, update stock levels, set min thresholds)**
  - **Assign ingredients to dishes with quantities**
  - **View calculated stock for menus and dishes**
  - **Receive low-stock alerts**

- [ ] **Order Processing**
  - View all orders with filters (by status, by client)
  - Update order status through the lifecycle:
    - `pending` → `accepted` (validate order)
    - `accepted` → `preparing` (kitchen starts)
    - `preparing` → `delivering` (delivery starts)
    - `delivering` → `delivered` (delivery confirms)
    - `delivered` → `awaiting_material_return` (if material lent)
    - `awaiting_material_return` → `completed` (material returned)
    - `delivered` → `completed` (no material lending)
  - Cancel orders **only after contacting client** (must specify contact mode GSM/email + reason)

- [ ] **Review Moderation**
  - View pending customer reviews
  - Approve reviews (visible on homepage)
  - Reject reviews (not visible)

- [ ] **Restrictions**
  - ❌ Cannot cancel/modify orders without contacting client first
  - ❌ Cannot access admin analytics (charts, revenue)
  - ❌ Cannot create/disable user accounts

---

### 🟢 Client User (Utilisateur)

**Subject: "Un visiteur peut se créer un compte"**

- [ ] **Account Management**
  - Register with: last name, first name, GSM, email, postal address, secure password (10 chars min, 1 special, 1 uppercase, 1 lowercase, 1 digit)
  - Receive welcome email on registration
  - Login with email + password
  - Reset password via email link
  - Update personal information

- [ ] **Menu Browsing** (also available to visitors)
  - View all published menus (title, description, person_min, price)
  - View detailed menu page (all database fields, conditions highlighted)
  - Filter menus dynamically (no page reload):
    - By max price
    - By price range
    - By theme (Noël, Pâques, Classique, Événement)
    - By diet (Végétarien, Végan, Classique)
    - By minimum number of persons

- [ ] **Order Placement**
  - Click "Commander" from menu detail → redirected to order page
  - Auto-filled: name, email, GSM (from account)
  - Enter: delivery address, date, time
  - Delivery pricing: €5 + €0.59/km if outside Bordeaux
  - Select number of persons (minimum = menu's `person_min`)
  - Auto 10% discount if persons ≥ `person_min + 5`
  - View price breakdown before validation (menu price + delivery)
  - Receive confirmation email after ordering

- [ ] **Order Management**
  - View all orders with details
  - Cancel order (only if status = `pending`, before employee accepts)
  - Modify order (all fields except menu choice, only if status = `pending`)
  - Track order status with dates/times for each state change

- [ ] **Reviews**
  - Notified by email when order status = `completed`
  - Rate order: 1-5 stars + comment
  - Review linked to specific order

---

### 👁️ Visitor (non-authenticated)

- [ ] Browse homepage (company presentation, team, approved reviews)
- [ ] Browse all menus with filters
- [ ] View detailed menu pages
- [ ] Access contact page (title + description + email → sent to company by email)
- [ ] Redirected to login/register if attempting to order

---

## 🌟 Bonus Features (beyond subject scope)

These are implemented in the database schema for extensibility but not required by the subject:

- [ ] Loyalty program (points, redemption)
- [ ] Internal messaging between employees
- [ ] Support ticket system
- [ ] Kanban board configuration for order management
- [ ] Order tags (urgent, VIP, fragile)
- [ ] Notification preferences
- [ ] Ingredient stock management
- [ ] Time-off request management

---

## GDPR Compliance Requirements

### 🔒 Data Protection & Privacy

#### Right to Access
- [ ] Users can download all their personal data in machine-readable format (JSON/CSV)
- [ ] Data export includes: profile info, orders, reviews, communications

#### Right to Erasure (Right to be Forgotten)
- [ ] Soft deletion of user accounts (marked as deleted, not physically removed immediately)
- [ ] Automated anonymization after retention period (e.g., 30 days)
- [ ] Preserve anonymized data for legal/financial compliance (order history without PII)
- [ ] Clear user consent logs for data processing

#### Right to Rectification
- [ ] Users can update their personal information at any time
- [ ] Audit trail of all data modifications

#### Data Minimization
- [ ] Only collect necessary data for service provision
- [ ] Regular cleanup of unused/expired data
- [ ] Session data expiration (auto-logout after inactivity)

#### Consent Management
- [ ] Explicit consent for marketing communications
- [ ] Cookie consent management
- [ ] Granular privacy settings
- [ ] Easy opt-out mechanisms

#### Security Measures
- [ ] Password hashing (bcrypt/argon2)
- [ ] Encryption of sensitive data at rest
- [ ] TLS/SSL for data in transit
- [ ] Two-factor authentication (2FA) for admins
- [ ] Rate limiting to prevent brute force attacks
- [ ] SQL injection prevention (prepared statements)

#### Audit & Compliance
- [ ] Complete audit logs of data access and modifications
- [ ] Data breach notification system
- [ ] Regular security audits
- [ ] Data Processing Agreement (DPA) with third parties
