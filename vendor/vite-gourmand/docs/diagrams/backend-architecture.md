# Vite Gourmand — Architecture Backend (NestJS)

> Diagramme d'architecture multicouche du backend NestJS. Audité directement
> contre le code source pour garantir l'exactitude (37 contrôleurs réels,
> 50+ services, deux SGBD, IA Groq, SSE temps réel).

---

## 1. Vue d'ensemble — 4 couches

```mermaid
graph TD
    subgraph Client["🖥️ Client"]
        REQ[React 19 / Vite SPA<br/>vite-gourmand-withered-glitter-7902.fly.dev]
    end

    subgraph Middleware["🛡️ Couche transversale (middlewares + guards + interceptors)"]
        direction TB
        ENF["enforceHttps<br/>308 redirect HTTP → HTTPS"]
        BODY["json + urlencoded<br/>limite 10 MB"]
        HELMET["Helmet<br/>CSP, COOP, HSTS, X-Frame-Options"]
        COMP["Compression<br/>gzip"]
        CORS["CORS<br/>origins configurés"]
        CSRF["csrfProtection<br/>vérifie X-CSRF-Token"]
        THR["ThrottlerGuard<br/>20/s · 100/10s · 300/min"]
        JWT["JwtAuthGuard<br/>+ OptionalAuthGuard"]
        ROL["RolesGuard<br/>@Roles decorator"]
        VPIPE["CustomValidationPipe<br/>class-validator + forbidNonWhitelisted"]
        LOGI["LoggingInterceptor<br/>+ HttpLogInterceptor → SSE"]
        TFI["TransformInterceptor<br/>success · data · statusCode · path"]
        EXC["AllExceptionsFilter<br/>+ HttpExceptionFilter"]
    end

    subgraph Controllers["🚪 Couche Contrôleurs (37 contrôleurs HTTP)"]
        direction LR
        AuthDom["Auth & Identité<br/>AuthController · SessionController<br/>GdprController · ConsentController · RoleController"]
        CatalogDom["Catalogue<br/>MenuController · DishController<br/>AllergenController · DietController · ThemeController<br/>IngredientController · ImageController"]
        CommerceDom["Commerce<br/>OrderController · DeliveryController<br/>DiscountController · PromotionController · LoyaltyController"]
        CommDom["Communication<br/>UserController · MessageController<br/>NewsletterController · ContactController · SupportController"]
        OpsDom["Opérations<br/>AdminController · KanbanController<br/>TimeoffController · WorkingHoursController · SiteInfoController · ReviewController"]
        DevDom["Outils<br/>AiAgentController · LogController · AnalyticsController<br/>CrudController · UnsplashController · SeedController · AppController"]
    end

    subgraph Services["⚙️ Couche Services métier (50+ services)"]
        direction LR
        AuthS["AuthService<br/>PasswordService (bcrypt 12)<br/>TokenService (JWT 15min / 7j)"]
        OrderS["OrderService<br/>OrderStatusService<br/>(machine à états 9 statuts)"]
        MenuS["MenuService · DishService<br/>MenuImageService · ReviewService"]
        UserS["UserService · AddressService<br/>UserSessionService"]
        AdminS["AdminService · StatsService<br/>SeedService · KanbanService"]
        GdprS["GdprService<br/>ConsentService<br/>DataDeletionService"]
        SupportS["SupportService<br/>MessageService · NewsletterService<br/>NotificationService"]
        AiS["AiAgentService<br/>Groq SDK · LLaMA 3.3"]
        MailS["MailService<br/>nodemailer · Titan SMTP<br/>+ Resend API"]
        LogS["LogService<br/>buffer in-memory 500 entrées"]
    end

    subgraph DataAccess["🔌 Couche Accès aux données"]
        PRISMA[PrismaService<br/>Prisma 7<br/>44 modèles relationnels<br/>Pool pg + adapter]
        MONGO[Mongo services<br/>AuditLogService · UserActivityService<br/>OrderSnapshotService · MenuAnalyticsService<br/>DashboardStatsService · RevenueService · SearchAnalyticsService]
    end

    subgraph DBs["🗄️ Bases de données"]
        PG[(PostgreSQL<br/>Supabase EU-West<br/>PgBouncer + Supavisor)]
        MDB[(MongoDB<br/>Atlas<br/>7 collections analytics)]
    end

    subgraph External["🌐 Services externes"]
        GROQ[Groq API<br/>LLaMA 3.3]
        TITAN[Titan SMTP]
        RESEND[Resend API]
        UNSPL[Unsplash API]
        GOOGLE[Google OAuth<br/>accounts.google.com]
    end

    %% Flow
    REQ -->|HTTPS| Middleware
    Middleware --> Controllers
    Controllers --> Services
    Services --> DataAccess
    PRISMA --> PG
    MONGO --> MDB

    AiS -.->|outbound HTTPS| GROQ
    MailS -.->|SMTP 465| TITAN
    MailS -.->|HTTPS| RESEND
    Services -.->|images| UNSPL
    AuthS -.->|OAuth| GOOGLE

    LogS -->|SSE /api/logs/stream<br/>token-auth| REQ
```

---

## 2. Détail — chaîne d'exécution d'une requête (du clic au commit DB)

```mermaid
sequenceDiagram
    autonumber
    participant C as Client SPA
    participant FLY as Fly proxy (HTTPS)
    participant NEST as NestJS app

    C->>FLY: POST /api/orders<br/>Authorization: Bearer <jwt><br/>X-CSRF-Token: <token>
    FLY->>NEST: forward port 8080 + x-forwarded-proto

    Note over NEST: ─── Middleware Express ───
    NEST->>NEST: enforceHttps (already HTTPS → pass)
    NEST->>NEST: json + urlencoded (parse body)
    NEST->>NEST: Helmet (security headers)
    NEST->>NEST: Compression
    NEST->>NEST: CORS (origin allow-list)
    NEST->>NEST: csrfProtection (compare cookie ↔ header)

    Note over NEST: ─── Pipeline NestJS ───
    NEST->>NEST: ThrottlerGuard (rate limit OK?)
    NEST->>NEST: JwtAuthGuard (extract & verify JWT)
    NEST->>NEST: RolesGuard (@Roles('user') OK?)
    NEST->>NEST: ValidationPipe (CreateOrderDto)
    NEST->>NEST: LoggingInterceptor (start timer)

    Note over NEST: ─── Logique métier ───
    NEST->>NEST: OrderController.create()
    NEST->>NEST: OrderService.create()
    NEST->>NEST: OrderStatusService.validate('pending')
    NEST->>NEST: PrismaService.$transaction([...])
    NEST->>NEST: AuditLogService.log() (fire-and-forget)
    NEST->>NEST: NotificationService.notify()

    Note over NEST: ─── Réponse ───
    NEST->>NEST: TransformInterceptor wraps {success, data}
    NEST->>NEST: LoggingInterceptor (log duration)
    NEST->>NEST: HttpLogInterceptor (push to SSE buffer)
    NEST-->>FLY: 201 Created + JSON
    FLY-->>C: 201 + JSON
```

---

## 3. Machine à états des commandes

Implémentée dans [`OrderStatusService`](../../Back/src/order/order-status.service.ts) avec transitions validées avant chaque mise à jour, et historique persisté dans la table `OrderStatusHistory`.

```mermaid
stateDiagram-v2
    [*] --> pending: Client crée la commande
    pending --> confirmed: Admin/Employé valide
    pending --> cancelled: Client annule
    confirmed --> preparing: Cuisine démarre
    preparing --> cooking
    cooking --> assembling
    assembling --> ready
    ready --> delivery: Livreur assigné<br/>(DeliveryAssignment)
    delivery --> delivered: Preuve photo<br/>+ signature
    confirmed --> cancelled: Annulation employé<br/>+ motif obligatoire
    delivered --> [*]
    cancelled --> [*]
```

---

## 4. Inventaire exhaustif (audit du code, 2026-05-27)

### Contrôleurs (37 fichiers `*.controller.ts`)

| Domaine | Fichiers |
|---|---|
| Authentification & identité | `auth`, `session`, `gdpr`, `consent`, `role` |
| Catalogue | `menu`, `dish`, `allergen`, `diet`, `theme`, `ingredient`, `image` |
| Commerce | `order`, `delivery`, `discount`, `promotion`, `loyalty`, `review` |
| Communication | `user`, `message`, `newsletter`, `contact`, `support` |
| Opérations | `admin`, `kanban`, `timeoff`, `working-hours`, `site-info` |
| Outils & IA | `ai-agent`, `logging` (`log.controller`), `analytics`, `crud`, `unsplash`, `seed`, `app` |

### Services métier (50+ fichiers `*.service.ts`)

Cas notables où **plusieurs services par module** :
- `auth/` → `AuthService` + `PasswordService` + `TokenService`
- `order/` → `OrderService` + `OrderStatusService` (machine à états)
- `gdpr/` → `GdprService` + `ConsentService` + `DataDeletionService`
- `session/` → `SessionService` + `UserSessionService` + `AdminSessionService`
- `timeoff/` → `TimeoffService` + `EmployeeTimeoffService` + `AdminTimeoffService`
- `role/` → `RoleService` + `PermissionService` + `RolePermissionService`
- `image/` → `ImageService` + `MenuImageService` + `ReviewImageService`
- `admin/` → `AdminService` + `StatsService`
- `user/` → `UserService` + `AddressService` + `SessionService`

### Cross-cutting concerns (couche transversale globale)

| Type | Implémentation |
|---|---|
| Filtres | `AllExceptionsFilter`, `HttpExceptionFilter` |
| Guards | `JwtAuthGuard`, `OptionalAuthGuard`, `RolesGuard`, `ThrottlerGuard` |
| Interceptors | `LoggingInterceptor`, `HttpLogInterceptor` (alimente le SSE), `TransformInterceptor` |
| Pipes | `CustomValidationPipe` (class-validator), `SafeParseIntPipe` |
| Middlewares Express | `enforceHttps`, `csrfProtection`, body parsers, `helmet`, `compression`, CORS |

### Accès aux données

- **PostgreSQL via Prisma 7** : 44 modèles relationnels. `PrismaService` étend `PrismaClient` avec lifecycle hooks NestJS (`onModuleInit`/`onModuleDestroy`), pool `pg` + `PrismaPg` adapter via PgBouncer.
- **MongoDB Atlas** : 7 services qui consomment 7 collections analytics : `audit-log`, `user-activity`, `order-snapshot`, `menu-analytics`, `dashboard-stats`, `revenue`, `search-analytics`. Driver natif `mongodb` (singleton, `maxPoolSize: 10`).

### Intégrations externes

| Service | Usage |
|---|---|
| **Groq API** (`@groq/sdk`) | LLaMA 3.3 pour l'assistant IA (composeur de menu, conseil événement) |
| **Titan SMTP** (`nodemailer`) | E-mails transactionnels |
| **Resend** (HTTPS) | Fallback d'envoi e-mail si Titan indisponible |
| **Unsplash API** | Recherche d'images pour les menus |
| **Google OAuth** (Passport.js) | Connexion sociale, gated par consentement RGPD |

---

## 5. Ce qu'on peut prouver aux jurys (CP6, CP7, CP9, CP10)

| Compétence | Preuve dans le diagramme |
|---|---|
| **CP6 — Composants d'accès SQL et NoSQL** | Couche dédiée `PrismaService` (44 modèles) + 7 services Mongo, séparés des services métier |
| **CP7 — Architecture multicouche répartie sécurisée** | 4 couches strictement séparées + couche transversale (Helmet, CSP, CORS, rate limit, JWT, RBAC, CSRF, validation) — la sécurité **ne touche pas** au code métier |
| **CP8 — Composants métier serveur** | 50+ services regroupés par domaine, plusieurs services par module quand la responsabilité unique l'exige (Auth = 3 services, Order = 2 services dont une FSM) |
| **CP9 — Application multicouche** | Le diagramme de séquence § 2 montre la traversée des 4 couches sans court-circuit, avec wrappers de réponse uniformes et journalisation transversale |
| **CP10 — APIs externes** | 5 intégrations distinctes (Groq, Titan, Resend, Unsplash, Google OAuth) avec gestion d'erreurs *fire-and-forget* pour ne pas bloquer le métier |
| **Plus-value : temps réel** | `LogService` → SSE `/api/logs/stream` (authentifié par token JWT en query string) → DevBoard live |

---

## 6. Comment exporter

1. Aller sur **https://mermaid.live**
2. Coller un des blocs `mermaid` ci-dessus
3. Export → PNG (zoom 2× pour qualité haute résolution)
4. A4 paysage recommandé pour le diagramme global ; portrait pour la machine à états et le diagramme de séquence

Pour le dossier DREETS : insérer la **vue d'ensemble** comme **Figure 1** (architecture globale), le **diagramme de séquence** comme **Figure 2** (parcours d'une requête), et la **machine à états** comme **Figure 3** (cycle de vie d'une commande).
