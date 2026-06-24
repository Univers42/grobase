# 🎯 SYSTÈME COMPLET - POINTS, AFFILIATION & AVIS

## ✅ NOUVEAU USERSPACE - PROFESSIONNEL & MODERNE

### 🎨 Design Amélioré
- **Interface moderne** avec gradient backgrounds et cartes animées
- **SVG animés** pour donner vie aux commandes
- **Cartes simplifiées** pour les commandes en cours (header = statut + icône)
- **Motion animations** (Framer Motion) pour transitions fluides
- **Responsive** et optimisé mobile/desktop

### 📊 Onglets Disponibles

#### 1. **Vue d'ensemble** 
- **4 statistiques clés** :
  - Commandes en cours (badge bleu)
  - Commandes totales (badge vert)
  - Points fidélité (badge orange)
  - Économies réalisées (badge violet)
  
- **Barre de progression** vers la prochaine récompense
  - Affiche les points actuels vs objectif
  - Message motivant
  
- **Actions rapides** :
  - Parcourir les menus
  - Badge notification pour avis à donner

#### 2. **Commandes en cours**
- **Vue carte moderne** avec :
  - Icône de statut animée (Clock, ChefHat, Truck, CheckCircle)
  - Nom du menu + nombre de personnes
  - Barre de progression selon le statut
  - Date de livraison + montant
  - Bouton "Voir les détails"
  
- **Statuts avec progression** :
  - Confirmée (10%)
  - Initiation (25%)
  - En préparation (40%)
  - Assemblage (50%)
  - Cuisson (60%)
  - Emballage (75%)
  - En livraison (85%)
  - Terminée (100%)

- **Message vide état** si aucune commande active

#### 3. **Historique**
- Liste toutes les commandes terminées
- **Badge "points gagnés"** sur chaque commande
- **Notification badge rouge** sur les commandes sans avis
- Bouton "Donner un avis" avec pastille animée rouge

#### 4. **Mes avis**
- **Section "À évaluer"** (fond orange) :
  - Liste des commandes terminées sans avis
  - Badge orange avec nombre de commandes
  - Message : "Gagnez 50 points par avis !"
  - Bouton direct pour évaluer
  
- **Section "Avis publiés"** :
  - Historique des avis validés

- **Modal d'évaluation** :
  - Sélection d'étoiles (1-5) interactive
  - Commentaire optionnel (max 200 caractères)
  - Compteur de caractères
  - Badge vert : "Vous gagnerez 50 points !"

#### 5. **Programme d'affiliation**

**Si NON affilié** :
- **Card attractive** (gradient purple-pink)
- **Explication en 3 étapes** :
  1. Partagez votre code
  2. Vos amis commandent
  3. Gagnez 10% en crédit
- Bouton "Rejoindre le programme"

**Si affilié** :
- **Carte avec code** :
  - Code affiché en grand (format: VG + userID)
  - Bouton "Copier le code"
  
- **Carte gains** :
  - Montant total des économies
  - Statistiques des parrainages

#### 6. **Paramètres**
- Modification du profil
- Prénom, nom, téléphone, adresse

---

## 💰 SYSTÈME DE POINTS FONCTIONNEL

### Algorithme de Calcul

#### Points gagnés à la COMMANDE :
```
Points base = Montant total de la commande (arrondi)
Exemple: 89.50€ → 89 points
```

#### Points bonus pour AVIS :
```
Points avis = 50 points fixes
```

#### Système de récompenses :
```
- 500 points = 10€ de réduction
- 1000 points = 25€ de réduction
- 2000 points = 60€ de réduction
```

### Routes Backend

**GET `/user/:userId/profile`**
```json
{
  "profile": {
    "points": 450,
    "totalOrders": 12,
    "affiliateCode": "VGABC123",
    "isAffiliate": true,
    "totalSavings": 45.50,
    "nextRewardAt": 500,
    "referredBy": null
  }
}
```

**POST `/orders/:orderId/complete`**
- Marque la commande comme terminée
- Calcule et attribue les points (1 point/euro)
- Gère le bonus d'affiliation si applicable
```json
{
  "success": true,
  "pointsEarned": 89,
  "totalPoints": 539
}
```

**POST `/orders/:orderId/review`**
- Crée un avis pour la commande
- Attribue 50 points bonus
- Marque la commande comme évaluée
```json
{
  "success": true,
  "review": {...},
  "pointsEarned": 50,
  "totalPoints": 589
}
```

**POST `/user/:userId/redeem-points`**
```json
Request:
{
  "points": 500
}

Response:
{
  "success": true,
  "pointsRedeemed": 500,
  "savingsEarned": 10,
  "remainingPoints": 89,
  "totalSavings": 55.50
}
```

---

## 🤝 SYSTÈME D'AFFILIATION

### Principe
1. **Utilisateur rejoint** le programme → obtient un code unique
2. **Partage son code** avec ses amis
3. **Ami utilise le code** lors de sa première commande
4. **Parrain reçoit 10%** du montant de chaque commande de son filleul

### Fonctionnement Technique

**Structure UserProfile** :
```typescript
{
  userId: string,
  isAffiliate: boolean,
  affiliateCode: string, // Format: VG + 6 premiers chars du userID
  referredBy: string | null, // userID du parrain
  totalSavings: number, // Crédits accumulés
  points: number
}
```

**POST `/user/:userId/join-affiliate`**
- Génère un code unique (VG + userID tronqué)
- Active le statut affilié
- Retourne le code à partager

**Logique lors de la COMPLÉTION d'une commande** :
```javascript
if (user.referredBy && referrer.isAffiliate) {
  const bonus = orderTotal * 0.10; // 10% du montant
  referrer.totalSavings += bonus;
}
```

### Exemple Concret
```
Marie (parrain) → Code: VGMAR123
Pierre utilise le code de Marie
Pierre commande pour 100€

Résultat:
- Pierre : 100 points + sa commande
- Marie : +10€ de crédit (totalSavings)
```

---

## ⭐ SYSTÈME D'AVIS CLIENTS

### Fonctionnement

1. **Commande terminée** → Apparaît dans "Mes avis" avec badge rouge
2. **Utilisateur clique** "Donner un avis"
3. **Modal s'ouvre** :
   - Sélection étoiles (1-5)
   - Commentaire optionnel (max 200 chars)
   - Badge : "Gagnez 50 points"
4. **Soumission** :
   - Avis créé (status: non validé)
   - 50 points attribués immédiatement
   - Commande marquée avec reviewId
5. **Validation admin** :
   - Admin valide l'avis
   - Avis devient public sur le site

### Règles
- ✅ 1 avis par commande maximum
- ✅ Seulement pour commandes terminées
- ✅ Points attribués immédiatement
- ✅ Avis doit être validé par admin pour être public

---

## 🗄️ STRUCTURE DE DONNÉES (KV STORE)

### Collection: `user_profiles`
```javascript
{
  "userId1": {
    points: 450,
    totalOrders: 8,
    affiliateCode: "VGUSER1",
    isAffiliate: true,
    referredBy: null,
    totalSavings: 23.50,
    nextRewardAt: 500
  },
  "userId2": {
    points: 120,
    totalOrders: 2,
    affiliateCode: "",
    isAffiliate: false,
    referredBy: "userId1", // Parrainé par userId1
    totalSavings: 0,
    nextRewardAt: 500
  }
}
```

### Collection: `orders` (champs ajoutés)
```javascript
{
  id: "ord-123",
  userId: "userId1",
  // ... autres champs ...
  reviewId: "rev-456" | null,
  pointsEarnedOnCompletion: 89,
  pointsEarned: 50, // Bonus avis
  completedAt: "2026-02-03T10:30:00Z"
}
```

### Collection: `reviews`
```javascript
{
  id: "rev-456",
  orderId: "ord-123",
  userId: "userId1",
  userName: "Marie Dubois",
  rating: 5,
  text: "Excellent service !",
  createdAt: "2026-02-03T11:00:00Z",
  validated: false // Admin doit valider
}
```

---

## 🎯 WORKFLOW COMPLET

### Scénario 1 : Nouvelle Commande
1. Client passe commande → 0 points
2. Admin traite la commande (Kanban)
3. Statut change : confirmed → preparing → delivery → completed
4. **Backend appelle** `POST /orders/:id/complete`
5. Points calculés (montant € = points) et attribués
6. Si client a un parrain affilié → Parrain gagne 10% en crédit
7. Commande apparaît dans "Historique" avec badge "+X points"

### Scénario 2 : Donner un Avis
1. Commande terminée sans avis → Badge rouge dans historique
2. Notification dans onglet "Mes avis"
3. Client clique "Donner un avis"
4. Modal : note étoiles + commentaire
5. **Soumission** → `POST /orders/:id/review`
6. Backend :
   - Crée l'avis (validated: false)
   - Attribue 50 points
   - Marque commande avec reviewId
7. Toast : "Avis envoyé ! +50 points gagnés 🎉"
8. Badge disparaît

### Scénario 3 : Rejoindre l'Affiliation
1. Client va dans "Affiliation"
2. Voit explication du programme
3. Clique "Rejoindre"
4. **Backend** → `POST /user/:id/join-affiliate`
5. Code généré (ex: VGMAR456)
6. Interface change → Affiche le code + statistiques
7. Client partage le code

### Scénario 4 : Utiliser Code Affiliation
1. Nouvel utilisateur s'inscrit
2. Entre le code parrain (ex: VGMAR456)
3. Backend enregistre `referredBy: "marId"`
4. À chaque commande complétée :
   - Filleul gagne ses points normaux
   - Parrain gagne 10% du montant en crédit

### Scénario 5 : Échanger des Points
1. Client a 550 points
2. Va dans profil ou récompenses
3. Clique "Échanger 500 points"
4. **Backend** → `POST /user/:id/redeem-points`
5. Déduction : 500 points → +10€ crédit
6. Points restants: 50
7. Crédit utilisable sur prochaine commande

---

## 🔧 ROUTES BACKEND AJOUTÉES

| Méthode | Route | Description |
|---------|-------|-------------|
| GET | `/user/:userId/profile` | Profil utilisateur avec points |
| POST | `/user/:userId/join-affiliate` | Rejoindre programme affiliation |
| POST | `/orders/:orderId/review` | Soumettre avis + gagner 50 points |
| POST | `/orders/:orderId/complete` | Marquer commande terminée + attribuer points |
| GET | `/orders/user/:userId` | Toutes les commandes d'un utilisateur |
| POST | `/user/:userId/redeem-points` | Échanger points contre crédit |

---

## 🎨 COMPOSANTS CRÉÉS/MODIFIÉS

### Nouveaux
- `/components/UserSpaceNew.tsx` - Espace utilisateur complet refait

### Modifiés
- `/App.tsx` - Import du nouveau UserSpace
- `/supabase/functions/server/index.tsx` - Toutes les routes de gestion

---

## 🚀 FONCTIONNALITÉS PRINCIPALES

### ✅ Points Automatiques
- Calcul automatique lors de la complétion
- 1€ = 1 point
- Persistance en base de données

### ✅ Bonus Avis
- 50 points par avis soumis
- Limitation 1 avis/commande
- Validation admin requise

### ✅ Programme Affiliation
- Code unique généré automatiquement
- Tracking des filleuls
- 10% de commission sur chaque vente
- Crédits cumulés utilisables

### ✅ Interface Moderne
- Cartes animées avec Motion
- SVG dynamiques selon le statut
- Badges de notification
- Design professionnel et épuré

### ✅ Gamification
- Barre de progression vers récompenses
- Badges visuels pour actions à faire
- Messages motivants
- Statistiques détaillées

---

## 📱 EXPÉRIENCE UTILISATEUR

### Points Forts
1. **Vue simplifiée** des commandes en cours (pas de surcharge d'info)
2. **Notifications visuelles** pour avis à donner (badge rouge animé)
3. **Progression claire** avec barres et pourcentages
4. **Actions rapides** accessibles depuis la vue d'ensemble
5. **Feedback immédiat** (toasts) pour chaque action

### Notifications
- Badge rouge sur commandes sans avis
- Badge orange sur onglet "Mes avis" si avis en attente
- Badge sur action rapide "Donnez votre avis"

---

## 🔐 SÉCURITÉ

- Vérification côté backend avant attribution de points
- Limitation 1 avis par commande (vérification avec reviewId)
- Calculs côté serveur (pas client)
- Validation admin requise pour avis publics

---

## 📊 MÉTRIQUES & ANALYTICS

Les données collectées permettent de tracker:
- Taux de conversion avis (commandes terminées vs avis donnés)
- Performance du programme d'affiliation
- Engagement utilisateur (points gagnés/utilisés)
- Satisfaction client (moyenne des notes)

---

## 🎓 GUIDE D'UTILISATION

### Pour le Client

1. **Passer une commande** → Gagne points automatiquement à la livraison
2. **Donner un avis** → +50 points bonus
3. **Rejoindre l'affiliation** → Partager son code
4. **Échanger points** → Crédit pour prochaine commande

### Pour l'Admin

1. **Compléter une commande** dans Kanban → Points attribués auto
2. **Valider les avis** dans "Contenu Site" → Avis devient public
3. **Voir stats utilisateurs** dans "Utilisateurs" → Points et historique

---

## ✨ SYSTÈME 100% FONCTIONNEL

Toutes les fonctionnalités sont implémentées et opérationnelles :
- ✅ Chargement des commandes depuis le backend
- ✅ Calcul automatique des points
- ✅ Système d'avis avec bonus
- ✅ Programme d'affiliation complet
- ✅ Interface moderne et professionnelle
- ✅ Notifications et badges
- ✅ Persistence des données
- ✅ Sécurité et validations

**Le système est prêt pour la production ! 🎉**
