# 🏗️ Architecture Technique - Vite & Gourmand

## Vue d'ensemble

L'application Vite & Gourmand est construite avec une architecture moderne à trois niveaux (three-tier architecture) :

```
┌─────────────────────────────────────────────────┐
│           FRONTEND (React + TypeScript)          │
│  ┌──────────────────────────────────────────┐   │
│  │  Components UI (Shadcn/ui)               │   │
│  │  State Management (React Hooks)          │   │
│  │  Routing (Client-side)                   │   │
│  │  Charts (Recharts)                       │   │
│  └──────────────────────────────────────────┘   │
└─────────────────┬───────────────────────────────┘
                  │ HTTPS / JWT
                  ▼
┌─────────────────────────────────────────────────┐
│         SERVER (Deno + Hono Framework)           │
│  ┌──────────────────────────────────────────┐   │
│  │  REST API Routes                         │   │
│  │  Authentication Middleware               │   │
│  │  RBAC (Role-Based Access Control)        │   │
│  │  Business Logic                          │   │
│  └──────────────────────────────────────────┘   │
└─────────────────┬───────────────────────────────┘
                  │ SQL / KV Operations
                  ▼
┌─────────────────────────────────────────────────┐
│        DATABASE (Supabase PostgreSQL)            │
│  ┌──────────────────────────────────────────┐   │
│  │  KV Store (Key-Value)                    │   │
│  │  - user_roles                            │   │
│  │  - menus                                 │   │
│  │  - orders                                │   │
│  │  - reviews                               │   │
│  │  - system_logs (NoSQL simulation)        │   │
│  │                                          │   │
│  │  Auth System (Supabase Auth)            │   │
│  │  - JWT tokens                            │   │
│  │  - Password hashing                      │   │
│  │  - Email confirmation                    │   │
│  └──────────────────────────────────────────┘   │
└─────────────────────────────────────────────────┘
```

---

## 📦 Structure du Projet

```
/
├── components/              # Composants React
│   ├── ui/                 # Composants UI de base (Shadcn)
│   │   ├── button.tsx
│   │   ├── card.tsx
│   │   ├── input.tsx
│   │   └── ...
│   ├── AdminDashboard.tsx  # Dashboard avec graphiques
│   ├── AdminPanel.tsx      # Panneau d'administration
│   ├── ContactPage.tsx     # Page de contact
│   ├── DesignSystemPage.tsx # Charte graphique
│   ├── DemoAccountsSetup.tsx # Configuration comptes démo
│   ├── Footer.tsx          # Pied de page
│   ├── HeroSection.tsx     # Section hero avec vidéo
│   ├── HomePage.tsx        # Page d'accueil
│   ├── LegalPage.tsx       # Pages légales
│   ├── LoginPage.tsx       # Page de connexion
│   ├── MenuDetailPage.tsx  # Détail d'un menu
│   ├── MenusPage.tsx       # Liste des menus
│   ├── Navbar.tsx          # Barre de navigation
│   ├── OrderPage.tsx       # Page de commande
│   └── UserSpace.tsx       # Espace utilisateur
│
├── supabase/
│   └── functions/
│       └── server/
│           ├── index.tsx   # Serveur Hono (API REST)
│           └── kv_store.tsx # Utilitaires KV Store
│
├── utils/
│   └── supabase/
│       └── info.tsx        # Configuration Supabase
│
├── styles/
│   └── globals.css         # Styles globaux + Tailwind
│
├── App.tsx                 # Composant racine
├── README.md               # Documentation principale
├── COMPTES_DEMO.md         # Identifiants de démonstration
└── ARCHITECTURE.md         # Ce fichier
```

---

## 🔐 Authentification & Autorisation

### Flux d'authentification

```
┌──────────┐         ┌──────────┐         ┌──────────┐
│  Client  │         │  Server  │         │ Supabase │
└────┬─────┘         └─���──┬─────┘         └────┬─────┘
     │                    │                     │
     │ 1. POST /signup    │                     │
     ├───────────────────>│                     │
     │                    │ 2. createUser()     │
     │                    ├────────────────────>│
     │                    │                     │
     │                    │ 3. User + Token     │
     │                    │<────────────────────┤
     │ 4. Success         │                     │
     │<───────────────────┤                     │
     │                    │                     │
     │ 5. Store token     │                     │
     │ (localStorage)     │                     │
     │                    │                     │
     │ 6. GET /profile    │                     │
     │ + Authorization    │                     │
     ├───────────────────>│                     │
     │                    │ 7. getUser(token)   │
     │                    ├────────────────────>│
     │                    │ 8. User data        │
     │                    │<────────────────────┤
     │ 9. User profile    │                     │
     │<───────────────────┤                     │
     │                    │                     │
```

### RBAC (Role-Based Access Control)

```typescript
// Hiérarchie des rôles
User (niveau 1)
├── Accès : Commandes, Profil, Avis
│
Employee (niveau 2)
├── Hérite de : User
├── Accès supplémentaire : Gestion menus, Gestion commandes
│
Admin (niveau 3)
├── Hérite de : Employee + User
├── Accès supplémentaire : Dashboard, Gestion employés, Logs système, Charte graphique
```

---

## 🗄️ Modèle de Données

### Table: user_roles

```typescript
{
  [userId: string]: 'user' | 'employee' | 'admin'
}
```

### Table: menus

```typescript
{
  id: string;
  title: string;
  description: string;
  images: string[]; // URLs
  theme: string; // 'mariage', 'anniversaire', etc.
  regime: string; // 'classique', 'vegan', etc.
  minPeople: number;
  price: number; // Prix pour minPeople
  conditions: string;
  stock: number;
  allergens: string[];
  dishes: Array<{
    id: string;
    name: string;
    description: string;
    type: string; // 'entrée', 'plat', 'dessert'
  }>;
  createdAt: string;
}
```

### Table: orders

```typescript
{
  id: string;
  userId: string;
  userName: string;
  userEmail: string;
  userPhone: string;
  menuId: string;
  menuTitle: string;
  numberOfPeople: number;
  deliveryAddress: string;
  deliveryCity: string;
  deliveryDate: string;
  deliveryTime: string;
  specialRequests?: string;
  menuPrice: number;
  deliveryFee: number;
  totalPrice: number;
  status: 'pending' | 'accepted' | 'preparing' | 'delivering' | 
          'delivered' | 'awaiting_equipment' | 'completed' | 'cancelled';
  statusHistory: Array<{
    status: string;
    date: string;
  }>;
  cancellationReason?: string;
  review?: {
    rating: number;
    comment: string;
    submittedAt: string;
  };
  createdAt: string;
}
```

### Table: reviews

```typescript
{
  id: string;
  orderId?: string;
  userId: string;
  userName: string;
  menuTitle?: string;
  rating: number; // 1-5
  text: string;
  validated: boolean;
  validatedAt?: string;
  validatedBy?: string;
  createdAt: string;
}
```

### Table: system_logs (NoSQL simulation)

```typescript
{
  id: string;
  userId?: string;
  type: 'system' | 'user_action' | 'admin_action';
  action: string;
  details: any;
  timestamp: string;
}
```

---

## 🔄 Flux de Données Principaux

### 1. Création de Commande

```
Client                Server               Database
  │                      │                     │
  │ 1. Sélection menu    │                     │
  │ 2. Formulaire        │                     │
  │ 3. POST /orders      │                     │
  ├─────────────────────>│                     │
  │                      │ 4. Vérifier auth    │
  │                      │ 5. Valider données  │
  │                      │ 6. Calculer prix    │
  │                      │    - Prix menu      │
  │                      │    - Livraison      │
  │                      │    - Réduction 10%  │
  │                      │ 7. Créer commande   │
  │                      ├────────────────────>│
  │                      │ 8. Confirmation     │
  │                      │<────────────────────┤
  │                      │ 9. Log action       │
  │                      ├────────────────────>│
  │ 10. Success + Order  │                     │
  │<─────────────────────┤                     │
  │ 11. Email (simulated)│                     │
  │                      │                     │
```

### 2. Mise à jour Statut Commande (Employé/Admin)

```
Employee              Server               Database
  │                      │                     │
  │ 1. PUT /admin/orders/:id/status          │
  ├─────────────────────>│                     │
  │                      │ 2. Vérifier auth    │
  │                      │ 3. Vérifier role    │
  │                      │    (employee/admin) │
  │                      │ 4. Valider statut   │
  │                      │ 5. Update commande  │
  │                      ├────────────────────>│
  │                      │ 6. Add to history   │
  │                      ├────────────────────>│
  │                      │ 7. Log action       │
  │                      ├────────────────────>│
  │                      │ 8. Confirmation     │
  │                      │<───��────────────────┤
  │ 9. Success           │                     │
  │<─────────────────────┤                     │
  │ 10. Email (simulated)│                     │
  │     si completed     │                     │
```

### 3. Validation d'Avis (Employé/Admin)

```
Employee              Server               Database
  │                      │                     │
  │ 1. PUT /admin/reviews/:id                 │
  │    { action: 'validate' }                 │
  ├─────────────────────>│                     │
  │                      │ 2. Vérifier auth    │
  │                      │ 3. Vérifier role    │
  │                      │ 4. Update review    │
  │                      │    - validated: true│
  │                      ├────────────────────>│
  │                      │ 5. Log action       │
  │                      ├────────────────────>│
  │ 6. Success           │                     │
  │<─────────────────────┤                     │
  │                      │                     │
```

---

## 📊 Dashboard & Analytics

### Architecture du Dashboard

```
AdminDashboard Component
│
├── fetchStatistics()
│   └── GET /admin/statistics
│       ├── Calcule orders par menu
│       ├── Calcule CA par menu
│       ├── Calcule total orders
│       └── Calcule total revenue
│
├── KPI Cards (4)
│   ├── CA total
│   ├── Commandes totales
│   ├── Revenu moyen
│   └── Menus actifs
│
├── Charts (4)
│   ├── BarChart - Orders par menu (Recharts)
│   ├── BarChart - CA par menu (Recharts)
│   ├── PieChart - Répartition CA (Recharts)
│   └── Top 5 Menus - Liste classée
│
├── Activity Feed
│   └── Dernières actions (simulées)
│
└── Summary Stats (3)
    ├── Taux de satisfaction
    ├── Taux de conversion
    └── Clients fidèles
```

### Calculs Automatiques

```typescript
// Réduction 10%
if (numberOfPeople >= menu.minPeople + 5) {
  price = price * 0.9;
}

// Frais de livraison
if (city.toLowerCase().includes('bordeaux')) {
  deliveryFee = 0;
} else {
  deliveryFee = 5 + (estimatedKm * 0.59);
}

// Prix total
totalPrice = menuPrice + deliveryFee;
```

---

## 🎨 Design System

### Composants Partagés

Tous les composants UI sont basés sur Shadcn/ui et personnalisés :

```
ui/
├── button.tsx         → 6 variantes
├── card.tsx          → Container principal
├── input.tsx         → Champs de formulaire
├── label.tsx         → Labels accessibles
├── select.tsx        → Menus déroulants
├── textarea.tsx      → Texte multi-ligne
├── badge.tsx         → Étiquettes colorées
├── alert.tsx         → Messages contextuels
├── tabs.tsx          → Navigation par onglets
├── dialog.tsx        → Modales
└── ...
```

### Thème Global

```css
/* globals.css */
@tailwind base;
@tailwind components;
@tailwind utilities;

:root {
  --primary: #ea580c;
  --primary-dark: #c2410c;
  --primary-light: #ffedd5;
  /* ... */
}
```

---

## 🔒 Sécurité

### Mesures Implémentées

1. **Authentication**
   - JWT tokens (Supabase Auth)
   - Password hashing (bcrypt)
   - Email confirmation
   - Password reset flow

2. **Authorization**
   - RBAC (3 niveaux)
   - Route protection middleware
   - Permission checks per action

3. **Input Validation**
   - Server-side validation
   - Type checking (TypeScript)
   - SQL injection prevention (KV Store)
   - XSS prevention (React escaping)

4. **Password Policy**
   - Minimum 10 caractères
   - Majuscule + minuscule
   - Chiffre + caractère spécial
   - Regex validation: `/^(?=.*[a-z])(?=.*[A-Z])(?=.*\d)(?=.*[@$!%*?&])[A-Za-z\d@$!%*?&]{10,}$/`

5. **CORS**
   - Headers configurés
   - Methods autorisés : GET, POST, PUT, DELETE, OPTIONS
   - Origin: * (développement)

---

## 🚀 Performance

### Optimisations Frontend

- **Code Splitting**: Composants chargés à la demande
- **Memoization**: React.memo pour éviter re-renders
- **Lazy Loading**: Images et composants lourds
- **Bundle Size**: Imports sélectifs (tree-shaking)

### Optimisations Backend

- **Connection Pooling**: Supabase gère les connexions
- **Indexing**: KV Store optimisé pour la recherche
- **Caching**: Données statiques en cache
- **Compression**: Réponses compressées (Deno)

### Métriques Cibles

- **FCP** (First Contentful Paint): < 1.5s
- **LCP** (Largest Contentful Paint): < 2.5s
- **FID** (First Input Delay): < 100ms
- **CLS** (Cumulative Layout Shift): < 0.1

---

## 🧪 Testing Strategy

### Niveaux de Tests

1. **Unit Tests**
   - Composants React isolés
   - Fonctions utilitaires
   - Validation des données

2. **Integration Tests**
   - Flux complets (commande, authentification)
   - API endpoints
   - Database operations

3. **E2E Tests**
   - Parcours utilisateur complets
   - Multi-roles (user, employee, admin)
   - Responsive design

4. **Manual Testing**
   - Comptes de démonstration
   - Scénarios réels
   - Edge cases

---

## 📈 Monitoring & Logs

### Logs Système

```typescript
// Structure d'un log
{
  id: string;
  userId?: string;
  type: 'system' | 'user_action' | 'admin_action';
  action: string;
  details: {
    // Context-specific data
  };
  timestamp: string;
}
```

### Types de Logs

- **Connexions**: Login, logout, échecs
- **Actions**: CRUD operations sur menus, commandes
- **Admin**: Création employés, validation avis
- **Erreurs**: Exceptions, timeouts, 500s
- **Performance**: Temps de réponse, queries lentes

### Accès aux Logs

- Route: `GET /admin/logs`
- Rôle requis: Admin
- Retourne: 100 derniers logs
- Tri: Par timestamp desc

---

## 🌐 Déploiement

### Environnements

1. **Development**
   - Local avec Deno
   - Supabase dev project
   - Hot reload activé

2. **Production**
   - Supabase Edge Functions
   - CDN pour assets statiques
   - SSL/TLS activé
   - Monitoring actif

### Variables d'Environnement

```bash
SUPABASE_URL=https://xxx.supabase.co
SUPABASE_ANON_KEY=eyJxxx...
SUPABASE_SERVICE_ROLE_KEY=eyJxxx...
SUPABASE_DB_URL=postgresql://xxx
```

---

## 🔮 Évolution Future

### Phase 2: Temps Réel
- WebSockets pour notifications live
- Mise à jour statut en temps réel
- Chat employé ↔ client

### Phase 3: Analytics Avancés
- Intégration MongoDB réelle
- Heatmaps d'utilisation
- Prédictions ML

### Phase 4: Scaling
- Microservices architecture
- Redis pour caching
- Load balancing
- CDN global

---

**📚 Pour plus d'informations, consultez :**
- [README.md](./README.md) - Documentation générale
- [COMPTES_DEMO.md](./COMPTES_DEMO.md) - Identifiants de test
