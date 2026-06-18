# Vite Gourmand — Gestion des cookies & consentement

> Système de consentement aux cookies conforme **RGPD** et aux **recommandations CNIL**.
> Mis en place en remplacement d'un service tiers (type CookieYes) pour garder le contrôle, éviter une dépendance externe et un coût récurrent.

---

## 1. Pourquoi ?

Le site dépose des cookies (session JWT, CSRF, préférences). Le RGPD et la CNIL imposent :

- **Consentement libre, spécifique, éclairé, univoque** avant tout cookie non strictement nécessaire.
- **Refuser aussi facile qu'accepter** : "Tout refuser" doit être aussi visible que "Tout accepter".
- **Cases décochées par défaut** pour les cookies optionnels (opt-in, jamais opt-out).
- **Choix révocable à tout moment** depuis n'importe quelle page.
- **Preuve du consentement** conservée (qui, quand, quoi, depuis quelle IP).
- **Re-demande tous les 13 mois maximum** (recommandation CNIL).

Avant cette implémentation, le site n'avait **aucun mécanisme de consentement** — non-conformité formelle.

---

## 2. Architecture — trois couches de stockage

| Donnée | Stockage | Pourquoi ce choix |
|---|---|---|
| **Choix actif du visiteur** (lu à chaque page : "dois-je charger GA ?") | `localStorage` + cookie 13 mois | Lecture synchrone, zéro round-trip, indispensable pour bloquer les scripts *avant* injection dans le DOM |
| **Consentement d'un compte connecté** (preuve de conformité liée à l'utilisateur) | PostgreSQL `UserConsent` (existant) | Relationnel, requêtable pour audit CNIL, lié au compte pour la portabilité RGPD |
| **Événements anonymes** (visiteur non connecté) | MongoDB `audit_logs` | Append-only, gros volume, pas de jointures relationnelles requises |

> **Note** : MongoDB seul aurait été un mauvais choix — la lecture synchrone côté client (la décision "charger GA ou pas") doit être *instantanée*. localStorage est la seule option viable pour ça.

---

## 3. Les quatre catégories de cookies

Conformes au modèle CNIL standard.

| Catégorie | Verrouillée | Description | Exemples dans Vite Gourmand |
|---|:---:|---|---|
| **Nécessaires** | ✅ Toujours actifs | Indispensables au fonctionnement (auth, sécurité, session). Le site ne marche pas sans eux. | JWT (`auth_token`), CSRF (`auth_csrf`), préférence de langue |
| **Fonctionnels** | ❌ Opt-in | Mémorisent les préférences utilisateur pour personnaliser la navigation. | Thème (clair/sombre), vue tableau/grille du dashboard, langue choisie |
| **Mesure d'audience** | ❌ Opt-in | Statistiques agrégées anonymisées pour améliorer le site. | *Préparé pour Plausible/GA — aucun installé à ce jour* |
| **Publicité & marketing** | ❌ Opt-in | Personnalisation publicitaire, retargeting, mesure de conversion. | *Préparé pour Meta Pixel/Google Ads — aucun installé à ce jour* |

Les deux dernières catégories sont **prêtes mais vides** : aucun script tiers de tracking n'est encore intégré. Quand ce sera le cas, le gating se fait automatiquement via `useConsent()` (voir §6).

---

## 4. Parcours utilisateur

### Premier passage sur le site
1. Le bandeau bas s'affiche avec **trois boutons de même prominence** : `Tout refuser` / `Personnaliser` / `Tout accepter`.
2. Tant que le visiteur n'a pas cliqué, **aucun cookie non-essentiel n'est déposé** et aucun script analytics ne tourne.
3. Le choix est enregistré dans `localStorage` (clé `vg.consent.v1`), mirroré dans un cookie 13 mois, et envoyé au backend (anonyme → Mongo, connecté → Postgres).

### Personnalisation
4. Le bouton **Personnaliser** ouvre une modal avec un toggle par catégorie.
5. Les catégories optionnelles sont **décochées par défaut** (opt-in CNIL).
6. La catégorie "Nécessaires" est affichée verrouillée avec un badge "Toujours actif".

### Modification ultérieure
7. Lien permanent **"Gérer mes cookies"** dans le pied de page → rouvre la modal pré-remplie avec les choix actuels.

### Expiration automatique
8. Après 13 mois, la décision expire et le bandeau réapparaît (limite légale française).

---

## 5. Fichiers du système

### Frontend (`View/`)

| Fichier | Responsabilité |
|---|---|
| [`src/contexts/ConsentContext.tsx`](../View/src/contexts/ConsentContext.tsx) | Provider React + hook `useConsent()`. Source de vérité côté client. Lit/écrit localStorage et cookie miroir. |
| [`src/services/consent.ts`](../View/src/services/consent.ts) | Couche réseau : route automatiquement vers `/api/gdpr/consent` (connecté) ou `/api/consent/anonymous` (anonyme). |
| [`src/components/legal/CookieBanner.tsx`](../View/src/components/legal/CookieBanner.tsx) | Bandeau bas, focus auto sur "Tout accepter", `role="dialog"`. |
| [`src/components/legal/CookiePreferences.tsx`](../View/src/components/legal/CookiePreferences.tsx) | Modal de personnalisation, fermable au clavier (Escape), focus-trap. |
| [`src/components/legal/CookieBanner.css`](../View/src/components/legal/CookieBanner.css) | Styles charte graphique (`#722F37` / `#D4AF37`), `prefers-reduced-motion` respecté. |
| [`src/App.tsx`](../View/src/App.tsx) | Monte `<ConsentProvider>` autour de l'app + `<CookieBanner />` hors `<Routes>`. |
| [`src/components/layout/Footer.tsx`](../View/src/components/layout/Footer.tsx) | Lien "Gérer mes cookies" via `useConsent().openPreferences()`. |

### Backend (`Back/`)

| Fichier | Responsabilité |
|---|---|
| [`src/consent/consent.controller.ts`](../Back/src/consent/consent.controller.ts) | `POST /api/consent/anonymous` (route publique) → MongoDB `audit_logs`. IP hashée SHA-256. |
| [`src/consent/consent.module.ts`](../Back/src/consent/consent.module.ts) | Module Nest enregistré dans `app.module.ts`. |
| `src/gdpr/consent.service.ts` (existant) | Gère `UserConsent` PostgreSQL pour utilisateurs connectés. |
| `src/Model/nosql/services/audit-log.service.ts` (existant) | Service d'écriture vers MongoDB. |

---

## 6. Comment intégrer un nouveau script tiers (Google Analytics, Plausible, etc.)

Le système de gating est déjà en place. Exemple pour Google Analytics 4 :

```tsx
import { useConsent } from '../contexts/ConsentContext';

function AnalyticsLoader() {
  const { choice } = useConsent();

  useEffect(() => {
    if (!choice?.analytics) return; // Pas de consentement → on ne charge rien

    const script = document.createElement('script');
    script.src = 'https://www.googletagmanager.com/gtag/js?id=G-XXXXXX';
    script.async = true;
    document.head.appendChild(script);

    return () => {
      script.remove(); // Si retrait du consentement, on retire le script
    };
  }, [choice?.analytics]);

  return null;
}
```

**Règle d'or** : ne jamais charger un script dans `<head>` au build. Toujours conditionner à `useConsent().choice?.<category>`.

---

## 7. Contrat API

### `POST /api/consent/anonymous` (public)

Visiteur non connecté qui valide ou modifie son choix.

**Request body** :
```json
{
  "action": "accept_all" | "reject_all" | "custom",
  "anonymousId": "uuid-côté-client",
  "categories": {
    "necessary": true,
    "functional": false,
    "analytics": false,
    "marketing": false
  }
}
```

**Response** : `204 No Content` (succès silencieux pour ne pas révéler la stratégie de stockage)

**Effet de bord** : un document est inséré dans `audit_logs` MongoDB :
```js
{
  action: 'create',
  entityType: 'consent_anonymous',
  newState: { action, categories, anonymousId },
  ipAddress: '<sha256 tronqué 32 chars>',  // jamais l'IP en clair
  userAgent: '<user-agent>',
  timestamp: ISODate
}
```

### `POST /api/gdpr/consent` (authentifié — déjà existant)

Pour les utilisateurs connectés. Écrit dans la table relationnelle `UserConsent`.

**Request body** :
```json
{ "consent_type": "analytics" | "functional" | "marketing", "consented": true }
```

---

## 8. Sécurité & vie privée

| Mesure | Mise en œuvre |
|---|---|
| Pas d'IP en clair en base | Hashage SHA-256 + sel (`JWT_SECRET`) tronqué à 32 chars |
| Pas de fingerprinting | Aucun ID stable côté serveur, juste un UUID client volatile (`anonymousId`) |
| Choix non-bloquant pour l'utilisateur | Endpoint en *fire-and-forget* — si Mongo est down, le visiteur ne le voit pas |
| Pas de tracking avant consentement | Aucun script analytics n'est chargé tant que `choice.analytics !== true` |
| Pas de "scroll = consentement" | La case par défaut est décochée et exige un clic actif (CNIL) |
| Stockage du choix | localStorage + cookie miroir avec `SameSite=Lax` et `Secure` en HTTPS |

---

## 9. Conformité CNIL — checklist

- [x] Bandeau affiché dès le premier passage
- [x] Boutons "Tout refuser" / "Personnaliser" / "Tout accepter" de même prominence visuelle
- [x] Cases décochées par défaut (opt-in)
- [x] Cookies nécessaires séparés et signalés comme non désactivables
- [x] Description claire de chaque catégorie + exemples
- [x] Choix révocable à tout moment (lien "Gérer mes cookies" dans le footer)
- [x] Re-prompt automatique après 13 mois
- [x] Preuve du consentement conservée (PG pour comptes, Mongo pour anonymes)
- [x] Aucun cookie non essentiel déposé avant consentement
- [x] Accessibilité clavier + lecteurs d'écran (`role="dialog"`, focus-trap, Escape)
- [x] `prefers-reduced-motion` respecté
- [x] IP anonymisée avant stockage

---

## 10. Limites connues & extensions futures

- **Aucun script analytics installé à ce jour** : le système est *prêt* pour brancher Plausible (recommandé, RGPD-friendly nativement) ou GA4. Voir §6.
- **Pas de différenciation EU/non-EU** : le bandeau s'affiche pour tous. La CNIL accepte cette approche pour un site français.
- **Pas de logs Server-Sent pour les changements de consentement utilisateur connecté** : si besoin d'audit temps réel, brancher un hook sur `UserConsent` Prisma.
- **Pas de version « cookie banner » alternative pour les iframes** : à ajouter si on intègre YouTube/Maps en embed avec cookies.
