# 📡 API Documentation - Vite & Gourmand

Base URL: `https://{projectId}.supabase.co/functions/v1/make-server-e87bab51`

---

## 🔐 Authentication

Toutes les routes protégées nécessitent un header d'autorisation :

```http
Authorization: Bearer {access_token}
```

---

## 📚 Table des Matières

1. [Authentication Routes](#authentication-routes)
2. [Menu Routes](#menu-routes)
3. [Order Routes](#order-routes)
4. [Review Routes](#review-routes)
5. [User Routes](#user-routes)
6. [Admin Routes](#admin-routes)
7. [System Routes](#system-routes)

---

## Authentication Routes

### POST /signup
Créer un nouveau compte utilisateur.

**Permissions**: Public

**Body**:
```json
{
  "email": "user@example.com",
  "password": "Password123!@#",
  "firstName": "Jean",
  "lastName": "Dupont",
  "phone": "+33 6 12 34 56 78",
  "address": "15 Rue Example, 33000 Bordeaux"
}
```

**Response 200**:
```json
{
  "success": true,
  "user": {
    "id": "uuid",
    "email": "user@example.com"
  }
}
```

**Validation**:
- Password: min 10 caractères, 1 majuscule, 1 minuscule, 1 chiffre, 1 caractère spécial
- Email: format valide
- Tous les champs requis

---

### POST /reset-password
Demander un lien de réinitialisation de mot de passe.

**Permissions**: Public

**Body**:
```json
{
  "email": "user@example.com"
}
```

**Response 200**:
```json
{
  "success": true,
  "message": "Si votre email existe, vous recevrez un lien de réinitialisation"
}
```

---

## Menu Routes

### GET /menus
Récupérer tous les menus disponibles.

**Permissions**: Public

**Response 200**:
```json
{
  "menus": [
    {
      "id": "uuid",
      "title": "Menu Gourmand",
      "description": "Un menu raffiné...",
      "images": ["url1", "url2"],
      "theme": "mariage",
      "regime": "classique",
      "minPeople": 10,
      "price": 450,
      "conditions": "Commande 48h à l'avance",
      "stock": 5,
      "allergens": ["gluten", "lactose"],
      "dishes": [
        {
          "id": "uuid",
          "name": "Foie gras mi-cuit",
          "description": "...",
          "type": "entrée"
        }
      ],
      "createdAt": "2026-02-03T10:00:00Z"
    }
  ]
}
```

---

### GET /menus/:id
Récupérer un menu spécifique.

**Permissions**: Public

**Response 200**:
```json
{
  "menu": {
    "id": "uuid",
    "title": "Menu Gourmand",
    ...
  }
}
```

**Response 404**:
```json
{
  "error": "Menu non trouvé"
}
```

---

### POST /menus
Créer un nouveau menu.

**Permissions**: Employee, Admin

**Body**:
```json
{
  "title": "Nouveau Menu",
  "description": "Description...",
  "images": ["url1"],
  "theme": "anniversaire",
  "regime": "vegan",
  "minPeople": 8,
  "price": 380,
  "conditions": "...",
  "stock": 10,
  "allergens": [],
  "dishes": [...]
}
```

**Response 200**:
```json
{
  "menu": {
    "id": "uuid",
    "createdAt": "2026-02-03T10:00:00Z",
    ...
  }
}
```

---

### PUT /menus/:id
Mettre à jour un menu existant.

**Permissions**: Employee, Admin

**Body**: Mêmes champs que POST (tous optionnels)

**Response 200**:
```json
{
  "menu": {
    "id": "uuid",
    ...
  }
}
```

---

### DELETE /menus/:id
Supprimer un menu.

**Permissions**: Employee, Admin

**Response 200**:
```json
{
  "success": true
}
```

---

## Order Routes

### POST /orders
Créer une nouvelle commande.

**Permissions**: User (authentifié)

**Body**:
```json
{
  "menuId": "uuid",
  "numberOfPeople": 12,
  "deliveryAddress": "42 Rue Example",
  "deliveryCity": "Bordeaux",
  "deliveryDate": "2026-03-15",
  "deliveryTime": "18:00",
  "specialRequests": "Allergie aux noix",
  "menuPrice": 540,
  "deliveryFee": 0,
  "totalPrice": 540
}
```

**Response 200**:
```json
{
  "order": {
    "id": "uuid",
    "userId": "uuid",
    "userName": "Jean Dupont",
    "userEmail": "user@example.com",
    "userPhone": "+33 6 12 34 56 78",
    "menuId": "uuid",
    "menuTitle": "Menu Gourmand",
    "numberOfPeople": 12,
    "deliveryAddress": "42 Rue Example",
    "deliveryCity": "Bordeaux",
    "deliveryDate": "2026-03-15",
    "deliveryTime": "18:00",
    "specialRequests": "Allergie aux noix",
    "menuPrice": 540,
    "deliveryFee": 0,
    "totalPrice": 540,
    "status": "pending",
    "statusHistory": [
      {
        "status": "Commande reçue",
        "date": "2026-02-03T10:00:00Z"
      }
    ],
    "createdAt": "2026-02-03T10:00:00Z"
  }
}
```

**Calculs Automatiques**:
- `menuPrice`: Prix de base × multiplicateur + réduction 10% si applicable
- `deliveryFee`: 0€ si Bordeaux, sinon 5€ + 0.59€/km
- `totalPrice`: menuPrice + deliveryFee

**Validation**:
- `numberOfPeople` ≥ `menu.minPeople`
- `deliveryDate` dans le futur
- Menu en stock disponible

---

### GET /orders
Récupérer toutes les commandes (Employee/Admin).

**Permissions**: Employee, Admin

**Response 200**:
```json
{
  "orders": [...]
}
```

---

### PUT /orders/:id/status
Mettre à jour le statut d'une commande (DEPRECATED - use /admin/orders/:id/status).

---

## User Routes

### GET /user/orders
Récupérer les commandes de l'utilisateur connecté.

**Permissions**: User (authentifié)

**Response 200**:
```json
{
  "orders": [
    {
      "id": "uuid",
      "menuTitle": "Menu Gourmand",
      "numberOfPeople": 12,
      "deliveryAddress": "42 Rue Example",
      "deliveryCity": "Bordeaux",
      "deliveryDate": "2026-03-15",
      "deliveryTime": "18:00",
      "totalPrice": 540,
      "deliveryFee": 0,
      "status": "accepted",
      "statusHistory": [...],
      "createdAt": "2026-02-03T10:00:00Z",
      "review": null
    }
  ]
}
```

---

### POST /user/orders/:id/cancel
Annuler une commande (uniquement si status = pending).

**Permissions**: User (propriétaire de la commande)

**Response 200**:
```json
{
  "success": true,
  "order": {
    "id": "uuid",
    "status": "cancelled",
    "cancellationReason": "Annulée par le client",
    ...
  }
}
```

**Response 400**:
```json
{
  "error": "Cette commande ne peut plus être annulée. Elle a déjà été acceptée par notre équipe."
}
```

---

### PUT /user/profile
Mettre à jour le profil de l'utilisateur connecté.

**Permissions**: User (authentifié)

**Body**:
```json
{
  "firstName": "Jean",
  "lastName": "Dupont",
  "phone": "+33 6 12 34 56 78",
  "address": "15 Rue Example, 33000 Bordeaux"
}
```

**Response 200**:
```json
{
  "success": true,
  "user": {
    "id": "uuid",
    "email": "user@example.com",
    "user_metadata": {
      "firstName": "Jean",
      "lastName": "Dupont",
      "phone": "+33 6 12 34 56 78",
      "address": "15 Rue Example, 33000 Bordeaux"
    }
  }
}
```

**Note**: L'email ne peut pas être modifié via cette route.

---

### POST /user/orders/:id/review
Soumettre un avis pour une commande terminée.

**Permissions**: User (propriétaire de la commande)

**Body**:
```json
{
  "rating": 5,
  "comment": "Excellent service et plats délicieux !"
}
```

**Response 200**:
```json
{
  "success": true,
  "review": {
    "id": "uuid",
    "orderId": "uuid",
    "userId": "uuid",
    "userName": "Jean Dupont",
    "menuTitle": "Menu Gourmand",
    "rating": 5,
    "text": "Excellent service et plats délicieux !",
    "validated": false,
    "createdAt": "2026-02-03T10:00:00Z"
  }
}
```

**Validation**:
- Rating: 1-5
- Commande doit être status = 'completed'
- Pas d'avis déjà soumis

---

## Review Routes

### GET /reviews
Récupérer tous les avis validés.

**Permissions**: Public

**Response 200**:
```json
{
  "reviews": [
    {
      "id": "uuid",
      "userName": "Jean Dupont",
      "rating": 5,
      "text": "Excellent !",
      "validated": true,
      "createdAt": "2026-02-03T10:00:00Z"
    }
  ]
}
```

---

### GET /reviews/all
Récupérer tous les avis (validés et non validés).

**Permissions**: Employee, Admin

**Response 200**:
```json
{
  "reviews": [
    {
      "id": "uuid",
      "userName": "Jean Dupont",
      "menuTitle": "Menu Gourmand",
      "rating": 5,
      "text": "Excellent !",
      "validated": false,
      "createdAt": "2026-02-03T10:00:00Z"
    }
  ]
}
```

---

## Admin Routes

### PUT /admin/orders/:id/status
Mettre à jour le statut d'une commande avec historique.

**Permissions**: Employee, Admin

**Body**:
```json
{
  "status": "accepted",
  "cancellationReason": "Client indisponible",
  "contactMethod": "GSM"
}
```

**Statuts valides**:
- `accepted` - Commande acceptée
- `preparing` - En préparation
- `delivering` - En cours de livraison
- `delivered` - Livrée
- `awaiting_equipment` - En attente du retour de matériel
- `completed` - Terminée
- `cancelled` - Annulée

**Response 200**:
```json
{
  "success": true,
  "order": {
    "id": "uuid",
    "status": "accepted",
    "statusHistory": [
      {
        "status": "Commande reçue",
        "date": "2026-02-03T10:00:00Z"
      },
      {
        "status": "Commande acceptée",
        "date": "2026-02-03T11:00:00Z"
      }
    ],
    ...
  }
}
```

**Validation pour annulation**:
- `cancellationReason` requis
- `contactMethod` requis (GSM ou email)

**Emails automatiques** (simulés):
- `awaiting_equipment` → Email rappel 10 jours + frais 600€
- `completed` → Email invitation à laisser un avis

---

### PUT /admin/reviews/:id
Valider ou rejeter un avis.

**Permissions**: Employee, Admin

**Body**:
```json
{
  "action": "validate"
}
```

**Actions valides**:
- `validate` - Valide l'avis (visible publiquement)
- `reject` - Rejette l'avis (supprimé)

**Response 200**:
```json
{
  "success": true
}
```

---

### POST /admin/employees
Créer un compte employé.

**Permissions**: Admin uniquement

**Body**:
```json
{
  "email": "employee@example.com",
  "password": "Employee123!@#",
  "firstName": "Pierre",
  "lastName": "Martin"
}
```

**Response 200**:
```json
{
  "success": true,
  "employee": {
    "id": "uuid",
    "email": "employee@example.com",
    "firstName": "Pierre",
    "lastName": "Martin"
  }
}
```

**Note**: Un email est simulé envoyé à l'employé (sans le mot de passe).

---

### POST /admin/employees/:id/disable
Désactiver un compte employé.

**Permissions**: Admin uniquement

**Response 200**:
```json
{
  "success": true
}
```

**Effet**: Le compte est banni pour ~100 ans (effectivement permanent).

---

### GET /admin/statistics
Récupérer les statistiques pour le dashboard.

**Permissions**: Admin uniquement

**Response 200**:
```json
{
  "ordersByMenu": [
    {
      "menu": "Menu Gourmand",
      "count": 15
    },
    {
      "menu": "Menu Vegan",
      "count": 8
    }
  ],
  "revenueByMenu": [
    {
      "menu": "Menu Gourmand",
      "revenue": 6750.00
    },
    {
      "menu": "Menu Vegan",
      "revenue": 3040.00
    }
  ],
  "totalOrders": 23,
  "totalRevenue": 9790.00
}
```

**Calculs**:
- Exclut les commandes annulées
- Arrondi à 2 décimales
- Groupé par titre de menu

---

### GET /admin/logs
Récupérer les logs système.

**Permissions**: Admin uniquement

**Response 200**:
```json
{
  "logs": [
    {
      "id": "uuid",
      "userId": "uuid",
      "type": "user_action",
      "action": "order_created",
      "details": {
        "orderId": "uuid",
        "menuId": "uuid"
      },
      "timestamp": "2026-02-03T10:00:00Z"
    }
  ]
}
```

**Limite**: 100 logs les plus récents

---

## System Routes

### GET /health
Vérifier l'état du serveur.

**Permissions**: Public

**Response 200**:
```json
{
  "status": "ok"
}
```

---

### GET /profile
Récupérer le profil de l'utilisateur connecté avec son rôle.

**Permissions**: User (authentifié)

**Response 200**:
```json
{
  "user": {
    "id": "uuid",
    "email": "user@example.com",
    "firstName": "Jean",
    "lastName": "Dupont",
    "phone": "+33 6 12 34 56 78",
    "address": "15 Rue Example, 33000 Bordeaux",
    "role": "user"
  }
}
```

---

### POST /init-data
Initialiser les données de démonstration.

**Permissions**: Public

**Response 200**:
```json
{
  "success": true,
  "message": "Sample data initialized"
}
```

**Crée**:
- 6 menus de démonstration
- 5 avis validés
- Tableaux vides pour orders

---

### POST /init-demo-accounts
Initialiser les comptes de démonstration.

**Permissions**: Public

**Response 200**:
```json
{
  "success": true,
  "message": "Demo accounts initialized"
}
```

**Crée**:
- admin@demo.app (Admin)
- employee@demo.app (Employee)
- user@demo.app (User)

---

## 🔴 Error Responses

### 400 Bad Request
Données invalides ou manquantes.

```json
{
  "error": "Le mot de passe doit contenir au minimum 10 caractères..."
}
```

### 401 Unauthorized
Token manquant ou invalide.

```json
{
  "error": "Non autorisé - vous devez être connecté"
}
```

### 403 Forbidden
Permissions insuffisantes.

```json
{
  "error": "Accès refusé - rôle insuffisant"
}
```

### 404 Not Found
Ressource introuvable.

```json
{
  "error": "Menu non trouvé"
}
```

### 500 Internal Server Error
Erreur serveur.

```json
{
  "error": "Erreur lors de la création de la commande"
}
```

---

## 📊 Rate Limiting

Actuellement aucune limite de taux n'est implémentée.

**Recommandations pour production**:
- 100 requêtes/minute pour routes publiques
- 1000 requêtes/minute pour utilisateurs authentifiés
- 5000 requêtes/minute pour admin

---

## 🔒 Security Headers

### CORS
```http
Access-Control-Allow-Origin: *
Access-Control-Allow-Methods: GET, POST, PUT, DELETE, OPTIONS
Access-Control-Allow-Headers: Content-Type, Authorization
Access-Control-Max-Age: 600
```

### Content-Type
```http
Content-Type: application/json
```

---

## 📝 Notes

### Emails Simulés
L'application simule l'envoi d'emails. Dans un environnement de production, intégrer un service d'emailing (SendGrid, AWS SES, etc.).

### Files Upload
Actuellement, les images sont référencées par URL. Pour un upload réel, implémenter Supabase Storage.

### Webhooks
Aucun webhook n'est actuellement implémenté. Considérer pour:
- Notifications temps réel
- Intégrations tierces
- Synchronisation externe

---

**📚 Documentation complémentaire**:
- [README.md](./README.md) - Vue d'ensemble
- [ARCHITECTURE.md](./ARCHITECTURE.md) - Architecture technique
- [COMPTES_DEMO.md](./COMPTES_DEMO.md) - Identifiants de test
