# API REST — Vue d'ensemble

## Oui, le projet utilise bien une API REST

Le backend est construit avec **NestJS v11** (sur Express), qui expose une API REST classique.  
Chaque ressource possède son propre module NestJS (`controller + service + dto`) qui répond aux verbes HTTP standard.

---

## Architecture générale

```
Navigateur / Frontend React (View/)
        │
        │  HTTP/S  — /api/*
        ▼
  NestJS (Back/)
  ┌──────────────────────────────────────┐
  │  Global middlewares                  │
  │  · ThrottlerGuard (rate-limiting)    │
  │  · JwtAuthGuard (authentification)  │
  │  · RolesGuard (autorisation)         │
  │  · TransformInterceptor (envelope)  │
  │  · CustomValidationPipe (DTO)        │
  ├──────────────────────────────────────┤
  │  Controller  (@Controller('route'))  │
  │  Service     (logique métier)        │
  │  Prisma      (ORM → PostgreSQL)      │
  └──────────────────────────────────────┘
```

---

## Format de réponse standardisé

Toutes les réponses passent par le `TransformInterceptor` (`Back/src/common/interceptors/transform.interceptor.ts`) qui enveloppe chaque résultat :

```json
{
  "success": true,
  "statusCode": 200,
  "message": "Data retrieved successfully",
  "data": { ... },
  "path": "/api/menus",
  "timestamp": "2026-05-27T10:00:00.000Z"
}
```

Le frontend doit donc toujours lire `response.data` pour accéder au contenu utile.

---

## Fichiers côté Backend (`Back/src/`)

### Structure par module (pattern répété pour chaque ressource)

```
Back/src/<resource>/
├── <resource>.controller.ts   ← routes HTTP (@Get, @Post, @Put, @Delete…)
├── <resource>.service.ts      ← logique métier + appels Prisma
├── <resource>.module.ts       ← déclaration NestJS du module
├── dto/<resource>.dto.ts      ← validation des données entrantes (class-validator)
└── index.ts                   ← exports publics du module
```

### Liste des modules REST actifs

| Module | Préfixe route | Fichier controller |
|--------|---------------|--------------------|
| Auth | `/api/auth` | [auth.controller.ts](../Back/src/auth/auth.controller.ts) |
| Menu | `/api/menus` | [menu.controller.ts](../Back/src/menu/menu.controller.ts) |
| Order | `/api/orders` | [order.controller.ts](../Back/src/order/order.controller.ts) |
| Dish | `/api/dishes` | [dish.controller.ts](../Back/src/dish/dish.controller.ts) |
| User | `/api/users` | [user.controller.ts](../Back/src/user/user.controller.ts) |
| Admin | `/api/admin` | [admin.controller.ts](../Back/src/admin/admin.controller.ts) |
| Allergen | `/api/allergens` | [allergen.controller.ts](../Back/src/allergen/allergen.controller.ts) |
| Diet | `/api/diets` | [diet.controller.ts](../Back/src/diet/diet.controller.ts) |
| Ingredient | `/api/ingredients` | [ingredient.controller.ts](../Back/src/ingredient/ingredient.controller.ts) |
| Review | `/api/reviews` | [review.controller.ts](../Back/src/review/review.controller.ts) |
| Contact | `/api/contact` | [contact.controller.ts](../Back/src/contact/contact.controller.ts) |
| Discount | `/api/discounts` | [discount.controller.ts](../Back/src/discount/discount.controller.ts) |
| Loyalty | `/api/loyalty` | [loyalty.controller.ts](../Back/src/loyalty/loyalty.controller.ts) |
| Delivery | `/api/delivery` | [delivery.controller.ts](../Back/src/delivery/delivery.controller.ts) |
| Message | `/api/messages` | [message.controller.ts](../Back/src/message/message.controller.ts) |
| Notification | `/api/notifications` | [notification.controller.ts](../Back/src/message/notification/notification.controller.ts) |
| Kanban | `/api/kanban` | [kanban.controller.ts](../Back/src/kanban/kanban.controller.ts) |
| GDPR | `/api/gdpr` | [gdpr.controller.ts](../Back/src/gdpr/gdpr.controller.ts) |
| Consent | `/api/consent` | [consent.controller.ts](../Back/src/consent/consent.controller.ts) |
| Session | `/api/sessions` | [session.controller.ts](../Back/src/session/session.controller.ts) |
| Image | `/api/images` | [image.controller.ts](../Back/src/image/image.controller.ts) |
| Role | `/api/roles` | [role.controller.ts](../Back/src/role/role.controller.ts) |
| Theme | `/api/themes` | [theme.controller.ts](../Back/src/theme/theme.controller.ts) |
| Working Hours | `/api/working-hours` | [working-hours.controller.ts](../Back/src/working-hours/working-hours.controller.ts) |
| Support | `/api/support` | [support.controller.ts](../Back/src/support/support.controller.ts) |
| Promotion | `/api/promotions` | [promotion.controller.ts](../Back/src/promotion/promotion.controller.ts) |
| Newsletter | `/api/newsletter` | [newsletter.controller.ts](../Back/src/newsletter/newsletter.controller.ts) |
| Analytics | `/api/analytics` | [analytics.controller.ts](../Back/src/analytics/analytics.controller.ts) |
| AI Agent | `/api/ai-agent` | [ai-agent.controller.ts](../Back/src/ai-agent/ai-agent.controller.ts) |
| Unsplash | `/api/unsplash` | [unsplash.controller.ts](../Back/src/unsplash/unsplash.controller.ts) |
| Site Info | `/api/site-info` | [site-info.controller.ts](../Back/src/site-info/site-info.controller.ts) |
| Seed | `/api/seed` | [seed.controller.ts](../Back/src/seed/seed.controller.ts) |
| TimeOff | `/api/timeoff` | [timeoff.controller.ts](../Back/src/timeoff/timeoff.controller.ts) |

### Fichiers communs (partagés par tous les modules)

| Fichier | Rôle |
|---------|------|
| [transform.interceptor.ts](../Back/src/common/interceptors/transform.interceptor.ts) | Enveloppe toutes les réponses dans `{ success, data, … }` |
| [jwt-auth.guard.ts](../Back/src/common/guards/jwt-auth.guard.ts) | Vérifie le JWT sur chaque route protégée |
| [roles.guard.ts](../Back/src/common/guards/roles.guard.ts) | Vérifie le rôle (`admin`, `manager`, `user`…) |
| [http-exception.filter.ts](../Back/src/common/filters/http-exception.filter.ts) | Formate les erreurs HTTP en JSON |
| [validation.pipe.ts](../Back/src/common/pipes/validation.pipe.ts) | Valide les DTOs entrants avec `class-validator` |
| [public.decorator.ts](../Back/src/common/decorators/public.decorator.ts) | Marque une route comme accessible sans JWT |
| [pagination.dto.ts](../Back/src/common/dto/pagination.dto.ts) | DTO partagé pour `page` / `limit` |

---

## Fichiers côté Frontend (`View/src/services/`)

### Principe : un service par domaine

Chaque fichier service encapsule les appels `fetch` vers une ressource backend.  
Ils s'appuient tous sur la fonction centrale `apiRequest()`.

```
View/src/services/
├── api.ts           ← wrapper fetch central (auth, CSRF, erreurs)
├── auth.ts          ← /api/auth/*
├── menus.ts         ← /api/menus, /api/themes, /api/diets
├── orders.ts        ← /api/orders/*
├── consent.ts       ← /api/consent/*
├── notifications.ts ← /api/notifications/*
├── newsletter.ts    ← /api/newsletter/*
├── testRunner.ts    ← /api/test-runner/*
├── public.ts        ← endpoints publics (site-info, etc.)
└── useMenus.ts      ← hook React autour de menus.ts
```

### `View/src/services/api.ts` — le cœur

C'est **le seul endroit** où `fetch()` est appelé directement.  
Il gère automatiquement :

- **URL de base** : lit `VITE_API_URL` (ou `/` par défaut pour le proxy Vite)
- **Cookies HTTPOnly** : le JWT est dans un cookie `httpOnly`, jamais en `localStorage`
- **CSRF** : lit le cookie `vg_csrf_token` et l'injecte en header `X-CSRF-Token` sur les mutations (`POST`, `PUT`, `PATCH`, `DELETE`)
- **Erreur 401** : efface automatiquement la session locale et lance `ApiError`
- **`credentials: 'include'`** : envoie les cookies cross-origin

```typescript
// Exemple d'utilisation
import { apiRequest } from './api';

const data = await apiRequest<MyType>('/api/menus', {
  method: 'GET',
});
```

### Authentification

L'auth REST utilise deux mécanismes complémentaires :

| Mécanisme | Cookie | Description |
|-----------|--------|-------------|
| JWT | `vg_auth_token` (httpOnly) | Identifie l'utilisateur — invisible au JS |
| CSRF token | `vg_csrf_token` (lisible) | Protège contre les attaques CSRF — envoyé en header |

Fichiers liés :
- [auth-cookie.constants.ts](../Back/src/auth/auth-cookie.constants.ts) — noms et durées des cookies
- [jwt.strategy.ts](../Back/src/auth/strategies/jwt.strategy.ts) — lecture du JWT depuis le cookie
- [google.strategy.ts](../Back/src/auth/strategies/google.strategy.ts) — OAuth Google

---

## Exemple complet : cycle d'une requête

```
1. Component React
   → appelle getMenus() dans View/src/services/menus.ts

2. menus.ts
   → appelle apiRequest('/api/menus') dans View/src/services/api.ts

3. api.ts
   → fetch('/api/menus', { credentials: 'include', headers: { X-CSRF-Token } })
   → Vite proxy (dev) ou Nginx (prod) forward vers http://localhost:3000

4. NestJS — Back/src/
   → ThrottlerGuard (rate limit)
   → JwtAuthGuard (lit cookie httpOnly, valide JWT) — @Public() ignore cette étape
   → RolesGuard (vérifie rôle si @Roles() présent)
   → CustomValidationPipe (valide les query params via DTO)
   → MenuController.findAll()  ← Back/src/menu/menu.controller.ts
   → MenuService.findAll()     ← Back/src/menu/menu.service.ts
   → PrismaClient.menu.findMany()

5. Réponse
   → TransformInterceptor enveloppe : { success, data, statusCode, path, timestamp }
   → HTTP 200 JSON

6. api.ts
   → response.json() → retourne l'objet enveloppé

7. menus.ts
   → lit response.data, transforme (transformMenu), retourne { menus[], meta }

8. Component React
   → affiche les menus
```

---

## Documentation Swagger

Une documentation interactive est auto-générée par `@nestjs/swagger`.  
En développement, elle est accessible à : **`http://localhost:3000/api/docs`**

Les controllers utilisent les décorateurs `@ApiTags`, `@ApiOperation`, `@ApiBearerAuth` pour enrichir cette documentation.

---

## Voir aussi

- [api-endpoints.md](./api-endpoints.md) — tableau de tous les endpoints
- [architecture.md](./ARCHITECTURE.md) — vue d'ensemble de l'architecture
- [security.md](./security.md) — détails sur JWT, CSRF, cookies
- [ORM.md](./ORM.md) — Prisma et le modèle de données
