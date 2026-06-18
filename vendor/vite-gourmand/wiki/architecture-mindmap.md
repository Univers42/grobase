# Cartographie Architecturale & Technique — Vite & Gourmand

> Mindmap exhaustive de tous les choix techniques et architecturaux du projet.  
> Générée depuis l'analyse du code source réel (mai 2026).

---

## Vue d'ensemble

```mermaid
mindmap
  root((Vite and Gourmand))
    FRONTEND
      Framework
        React 19
        TypeScript 5.9
        Vite 7
      UI et Style
        TailwindCSS 4
        Radix UI
        Lucide React
        class-variance-authority
        clsx / tailwind-merge
      Routing
        React Router DOM 7
        SPA client-side
        Routes protégées par rôle
      Data Fetching
        TanStack React Query 5
        Fetch natif via apiRequest
        Axios disponible
      State Global
        React Context API
        ConsentContext
        NotificationContext
        PublicDataContext
        ToastContext
      Tests
        Playwright 1.60
        Tests E2E
        axe-core accessibilité
    BACKEND
      Framework
        NestJS 11
        Express platform
        TypeScript 6
        RxJS 7
      Architecture
        37 Controllers REST
        Module pattern
        DTO validation
        Interceptors globaux
        Guards globaux
        Filtres exceptions
      ORM et BDD
        Prisma 7
        PostgreSQL
        MongoDB
        Dual database
      Auth
        Passport.js
        Strategy JWT
        Strategy Google OAuth2
        JWT HttpOnly Cookie
        CSRF Cookie
        bcrypt passwords
      Communication
        REST API principale
        Server-Sent Events SSE
        Socket.io WebSockets
      Email
        Nodemailer
        Titan SMTP
        Resend disponible
      IA
        OpenAI SDK
        Groq API
        LLaMA 3.3 70B
      Cache
        NestJS CacheManager
        TTL 60 secondes
        Max 100 items
      Internationalisation
        nestjs-i18n
        EN et FR
      Tests
        Jest 30
        Supertest
        Tests unitaires
        Tests E2E API
        Test Runner QA intégré
    BASE DE DONNÉES
      PostgreSQL
        Prisma ORM
        Row Level Security
        Migrations Prisma
        Seed scripts
        30+ modèles
      MongoDB
        Analytics temps réel
        Audit logs
        Order snapshots
        Dashboard stats
        Search analytics
        User activity logs
        Retention policy
      Données métier
        Menus et Plats
        Commandes
        Utilisateurs et Rôles
        Allergènes et Régimes
        Livraisons
        Fidélité
        Kanban
        RGPD et Consentements
    INFRASTRUCTURE
      Conteneurisation
        Docker
        Docker Compose
        Multi-services
        Volumes nommés
        Profiles dev/prod/tools
      Déploiement
        Fly.io
        Région Paris CDG
        HTTPS forcé
        Min 1 machine running
        Concurrence 200 requêtes
      Proxy
        Nginx prod
        Vite proxy dev
        Port 3000 backend
        Port 5173 frontend
      Secrets
        Bitwarden CLI
        Docker secrets service
        Variables ENV
      CI/CD
        GitHub Actions
        build.yml
        ci-cd.yml
      Qualité code
        SonarCloud
        ESLint
        Prettier
        TypeScript strict
    SECURITE
      Authentification
        JWT RS256
        Cookie HttpOnly
        TTL 15 minutes
        Google OAuth 2.0
        Dual extraction Bearer et Cookie
      Autorisation
        RBAC
        Rôles admin
        Rôles manager
        Rôles employee
        Rôles user
        Decorator Roles
        Guard RolesGuard
      Protection HTTP
        Helmet
        CORS
        CSP strict
        X-Frame-Options DENY
        X-Content-Type-Options
        COOP same-origin
        HSTS prod
      Anti-abus
        ThrottlerGuard
        20 req/seconde
        100 req/10 secondes
        300 req/minute
      RGPD
        ConsentContext
        CNIL 13 mois
        GDPR Controller
        Data Deletion Request
        Audit logs MongoDB
      CSRF
        Double cookie pattern
        vg-csrf-token lisible
        Header X-CSRF-Token
        Mutations uniquement
    PATTERNS ARCHITECTURAUX
      Monorepo
        Back et View séparés
        Makefile orchestration
        Scripts partagés
      Côté Backend
        Controller Service Repository
        Module NestJS par domaine
        DTO class-validator
        TransformInterceptor envelope
        HttpExceptionFilter JSON
        ValidationPipe global
        LoggingInterceptor
      Côté Frontend
        Services par domaine
        apiRequest wrapper central
        Hooks React custom
        Composants UI découplés
        Layouts et Pages séparés
      Réponse API
        Envelope success data
        statusCode message
        path et timestamp
        Pagination meta
    INTEGRATIONS TIERCES
      Images
        Unsplash API
        Optimisation WebP
        CDN externe
      OAuth
        Google Identity Services
        Google OAuth 2.0
        GSI frontend
      IA Générative
        Groq Cloud
        LLaMA 3.3 70B versatile
        Composition menu IA
        Mode démo sans clé
      Email
        Titan Email
        SMTP TLS 465
        Templates HTML
      Documentation
        Swagger OpenAPI
        Accessible /api/docs
        Décoré automatiquement
```

---

## Légende des couches

| Couche | Technologie principale | Rôle |
|--------|----------------------|------|
| **Frontend** | React 19 + Vite 7 | SPA — interface utilisateur |
| **Backend** | NestJS 11 + Express | API REST — logique métier |
| **BDD relationnelle** | PostgreSQL + Prisma 7 | Données transactionnelles |
| **BDD analytique** | MongoDB | Logs, stats, snapshots |
| **Infra** | Docker + Fly.io | Conteneurisation & déploiement |
| **CI/CD** | GitHub Actions + SonarCloud | Automatisation qualité |
| **Secrets** | Bitwarden CLI | Gestion sécurisée des clés |

---

## Zoom : flux de données complet

```mermaid
mindmap
  root((Flux de données))
    Requête entrante
      Navigateur envoie fetch
      Cookie JWT HttpOnly joint
      Cookie CSRF lu par JS
      Header X-CSRF-Token ajouté
      Proxy Vite dev OU Nginx prod
    Pipeline NestJS
      ThrottlerGuard contrôle débit
      JwtAuthGuard lit cookie
      JwtStrategy valide token
      RolesGuard vérifie permission
      ValidationPipe contrôle DTO
      Controller route vers Service
      Service appelle Prisma
      Prisma exécute SQL
    Réponse sortante
      Données brutes retournées
      TransformInterceptor enveloppe
      LoggingInterceptor trace
      JSON structuré renvoyé
      HttpExceptionFilter si erreur
    Côté client
      apiRequest reçoit JSON
      Lit response.data
      Service transforme format
      TanStack Query met en cache
      Composant React se met à jour
```

---

## Zoom : sécurité en couches

```mermaid
mindmap
  root((Sécurité))
    Réseau
      HTTPS obligatoire prod
      Fly.io TLS automatique
      HSTS 1 an
      Upgrade insecure requests
    HTTP Headers
      Helmet middleware
      CSP bloque injections
      X-Frame-Options DENY
      X-Content-Type-Options nosniff
      Referrer-Policy strict
      Permissions-Policy caméra micro
    API
      Rate limiting 3 niveaux
      CORS origine contrôlée
      CSRF double-cookie
      Input validation DTO
      Paramètres typés Prisma
    Authentification
      JWT signé secret
      HttpOnly pas accessible JS
      Expiration 15 minutes
      Google OAuth 2.0 alternatif
    Autorisation
      RBAC 5 niveaux de rôle
      Décorateur par route
      Guard global appliqué
      Route publique marquée
    Données
      bcrypt hash mots de passe
      Row Level Security Postgres
      Audit logs MongoDB
      Data deletion RGPD
      Consentement CNIL tracé
```

---

## Zoom : base de données hybride

```mermaid
mindmap
  root((Base de données hybride))
    PostgreSQL relationnel
      Modèles Prisma
        User et rôles
        Menu et Dish
        Order et OrderMenu
        Allergen et Diet
        Theme et Ingredient
        Review et Loyalty
        Delivery et Discount
        Kanban et WorkingHours
        Company et Event
        Consent et GDPR
        Newsletter et Contact
        Message et Support
        Promotion et Session
      Fonctionnalités
        Auto-increment IDs
        Timestamps created et updated
        Relations typées Prisma
        Partial indexes
        Row Level Security
        Migrations versionnées
        Seeds développement
    MongoDB NoSQL
      Collections analytiques
        menu-analytics vues et clics
        revenue-by-menu chiffre affaires
        dashboard-stats agrégats admin
        search-analytics requêtes
        user-activity-logs sessions
        audit-logs actions sensibles
        order-snapshots historique
      Fonctionnalités
        Retention policy automatique
        Indexes optimisés
        Agrégation temps réel
        Schéma flexible
        Init script Docker
    Choix hybride
      Postgres pour transactions ACID
      MongoDB pour volumes logs
      Séparation des responsabilités
      Performance lecture analytique
      Evolutivité indépendante
```

---

## Zoom : stack de tests

```mermaid
mindmap
  root((Tests))
    Backend Jest
      Tests unitaires services
      Tests controllers
      Supertest requêtes HTTP
      Tests E2E flows API
      Tests orders spécifiques
      Coverage LCOV
      runInBand séquentiel
      Memory limit 384 MB
    Frontend Playwright
      Tests E2E navigateur
      Interface utilisateur
      Mode UI interactif
      Scenarios auth
    QA intégré
      TestRunnerController
      Dashboard QA frontend
      Résultats temps réel
      Postman convert
      CI summary report
    Qualité statique
      ESLint TypeScript
      Prettier format
      SonarCloud analyse
      Hotspots sécurité
      Coverage rapport
    CI GitHub Actions
      build.yml compilation
      ci-cd.yml pipeline complet
      Tests automatisés PR
      Deploy Fly.io si OK
```

---

## Voir aussi

- [rest-api.md](./rest-api.md) — fichiers et structure de l'API REST
- [ARCHITECTURE.md](./ARCHITECTURE.md) — description textuelle de l'architecture
- [ORM.md](./ORM.md) — Prisma et schéma de données
- [security.md](./security.md) — détails sécurité
- [deployment.md](./deployment.md) — déploiement Fly.io
- [api-endpoints.md](./api-endpoints.md) — référence des endpoints
