# Vite Gourmand — Diagrammes de séquence

> Quatre parcours utilisateurs représentatifs, du clic dans le navigateur jusqu'à la persistance en base.
> Chaque scénario combine **un narratif** (le contexte métier) et **un diagramme Mermaid** (le détail technique).

---

## Scénario 1 — Un client passe une commande

### Contexte
Marion, particulière, souhaite commander le menu *Truffe & Champagne* pour son anniversaire (12 personnes). Le `person_min` du menu est 8 ; à partir de `person_min + 5 = 13` une remise automatique de 10 % s'applique. Marion est en dessous du seuil, mais elle dispose d'un code promo `BIENVENUE10`. Elle souhaite valider, payer, et recevoir une confirmation par e-mail.

### Déroulement métier
1. Marion ouvre le site, parcourt les menus filtrés par thème "Gastronomique".
2. Elle ouvre la fiche du menu, choisit 12 personnes, saisit l'adresse de livraison.
3. Elle entre `BIENVENUE10` (remise 10 %).
4. Le système calcule : `menu_price × 12` puis applique la remise + ajoute les frais de livraison.
5. La commande est créée avec le statut `pending`, l'historique de statut est initialisé, des points fidélité sont provisionnés, et un e-mail de confirmation part.

### Diagramme

```mermaid
sequenceDiagram
    autonumber
    actor C as Client (Marion)
    participant UI as React (View)
    participant API as NestJS API
    participant G as JwtAuthGuard
    participant V as ValidationPipe
    participant S as OrderService
    participant DB as PostgreSQL (Prisma)
    participant M as MongoDB (audit)
    participant Mail as Service e-mail

    C->>UI: Sélectionne menu "Truffe & Champagne"<br/>12 personnes, code BIENVENUE10
    UI->>API: POST /api/orders { menuId, personNumber, deliveryDate,<br/>deliveryAddress, totalPrice, discountCode }<br/>Authorization: Bearer <jwt>
    API->>G: Vérifie JWT
    G-->>API: ok (sub=42, role=client)
    API->>V: Valide CreateOrderDto
    V-->>API: ok

    API->>S: create(userId=42, dto)
    S->>DB: SELECT Menu WHERE id=:menuId<br/>(stock, person_min, price)
    DB-->>S: Menu {price_per_person:120, person_min:8, remaining_qty:25}

    S->>DB: SELECT Discount WHERE code='BIENVENUE10'<br/>AND is_active=true
    DB-->>S: Discount {value:10, type:'percent'}

    Note over S: Calcul:<br/>menu_price = 120 × 12 = 1440<br/>discount = 144 → total = 1296 + livraison

    S->>DB: BEGIN
    S->>DB: INSERT Order (status='pending', ...)
    DB-->>S: Order #1057
    S->>DB: INSERT OrderMenu (order_id, menu_id, qty=12)
    S->>DB: INSERT OrderStatusHistory (new='pending')
    S->>DB: UPDATE Menu SET remaining_qty = 25 - 1
    S->>DB: UPDATE Discount SET current_uses += 1
    S->>DB: INSERT LoyaltyTransaction (points=+129, type='earned_pending')
    S->>DB: COMMIT

    S->>M: AuditLog: order_created {orderId:1057, userId:42}
    S-->>Mail: Confirmation e-mail (template + total + numéro)
    Mail-->>C: 📧 "Votre commande #VG-1057 est en attente"

    S-->>API: Order {id:1057, status:'pending', total_price:1296}
    API-->>UI: 201 Created { success:true, data: order }
    UI-->>C: "Commande #VG-1057 confirmée — en attente de validation"
```

### Points techniques
- **Atomicité** : `BEGIN ... COMMIT` garantit que stock, remise, fidélité et commande sont cohérents.
- **Pré-validation** : `CreateOrderDto` rejette dates passées, adresses vides, prix négatifs.
- **Idempotence** : `order_number` est unique (`@unique`) ; double-clic = erreur 409 propre.
- **Décorrélation** : `AuditLog` MongoDB est *write-only* — l'écriture en NoSQL ne bloque pas la transaction SQL.

---

## Scénario 2 — Mot de passe oublié

### Contexte
Sébastien revient sur le site après plusieurs mois. Il ne se souvient plus de son mot de passe. Il clique sur *Mot de passe oublié*, saisit son e-mail, reçoit un lien contenant un token unique, choisit un nouveau mot de passe.

### Déroulement métier
1. Sébastien saisit `seb@exemple.fr` dans le formulaire *mot de passe oublié*.
2. Le backend ne révèle jamais si l'e-mail existe (anti-énumération).
3. Si l'utilisateur existe, un `PasswordResetToken` est créé avec une expiration de 1 h.
4. Un e-mail contenant `https://.../reset?token=...` est envoyé.
5. Sébastien clique, saisit son nouveau mot de passe, le backend valide le token, hashe le mot de passe (bcrypt 12 rounds), invalide le token.

### Diagramme

```mermaid
sequenceDiagram
    autonumber
    actor S as Sébastien
    participant UI as React (View)
    participant API as NestJS API
    participant Auth as AuthService
    participant Pwd as PasswordService
    participant DB as PostgreSQL
    participant Mail as Service e-mail

    %% Étape 1 — Demande
    S->>UI: Clique "Mot de passe oublié"<br/>saisit seb@exemple.fr
    UI->>API: POST /api/auth/forgot-password { email }
    API->>Auth: forgotPassword(email)
    Auth->>DB: SELECT User WHERE email = :email
    alt User trouvé
        DB-->>Auth: User { id:88 }
        Auth->>Auth: token = randomBytes(48).toHex()
        Auth->>DB: INSERT PasswordResetToken<br/>(user_id, token, expires_at = NOW + 1h, used=false)
        Auth->>Mail: sendResetEmail(email, token)
        Mail-->>S: 📧 lien /reset?token=...
    else User absent
        DB-->>Auth: null
        Note over Auth: Pas d'écriture, pas d'e-mail<br/>(anti-énumération)
    end
    Auth-->>API: { ok:true, message:"Si l'e-mail existe, un lien a été envoyé" }
    API-->>UI: 200 OK
    UI-->>S: "Vérifiez votre boîte e-mail"

    %% Étape 2 — Réinitialisation
    S->>UI: Ouvre le lien<br/>saisit nouveau mot de passe
    UI->>API: POST /api/auth/reset-password { token, newPassword }
    API->>Auth: resetPassword(token, newPassword)
    Auth->>DB: SELECT PasswordResetToken<br/>WHERE token = :token AND used=false<br/>AND expires_at > NOW
    alt Token valide
        DB-->>Auth: PRT { user_id:88 }
        Auth->>Pwd: hash(newPassword)
        Pwd-->>Auth: $2b$12$...
        Auth->>DB: BEGIN
        Auth->>DB: UPDATE User SET password = :hash<br/>WHERE id=88
        Auth->>DB: UPDATE PasswordResetToken<br/>SET used=true
        Auth->>DB: DELETE UserSession WHERE user_id=88<br/>(invalide les sessions actives)
        Auth->>DB: COMMIT
        Auth-->>API: { success:true }
        API-->>UI: 200 OK
        UI-->>S: "Mot de passe mis à jour, reconnectez-vous"
    else Token invalide/expiré
        Auth-->>API: 400 BadRequest
        API-->>UI: { error:"Lien expiré" }
        UI-->>S: "Demandez un nouveau lien"
    end
```

### Points techniques
- **Anti-énumération** : la réponse de l'étape 1 est identique que l'utilisateur existe ou non.
- **Token aléatoire** : 48 octets cryptographiquement sûrs (`crypto.randomBytes`).
- **Expiration courte** : 1 h, configurable via env.
- **Invalidation de session** : changer le mot de passe déconnecte les autres appareils (`DELETE UserSession`).
- **Hash bcrypt** : 12 rounds, conforme aux recommandations CNIL.

---

## Scénario 3 — Un employé fait avancer une commande sur le Kanban

### Contexte
Karim, employé en cuisine, ouvre son tableau Kanban. Il voit la commande #VG-1057 dans la colonne *Confirmée*. Il la déplace vers *En préparation*, ce qui doit déclencher la mise à jour atomique du statut, un historique, et une notification au client en temps réel.

### Déroulement métier
1. Karim s'authentifie, ouvre `/dashboard` (rôle employé).
2. Le tableau affiche les commandes regroupées par statut (`KanbanColumn.mapped_status`).
3. Karim glisse une carte de *confirmed* vers *preparing*.
4. Le backend valide la transition (machine d'états), persiste l'historique, notifie le client.
5. Le client connecté reçoit la notification via SSE (`Notification` + `useRealLogs` ne sert qu'aux logs ; ici c'est `Notification`).

### Diagramme

```mermaid
sequenceDiagram
    autonumber
    actor K as Karim (employé)
    actor C as Client (Marion)
    participant UI as React DevBoard
    participant API as NestJS API
    participant G as RolesGuard
    participant OS as OrderStatusService
    participant FSM as StatusTransitionValidator
    participant DB as PostgreSQL
    participant N as NotificationService
    participant SSE as SSE stream

    K->>UI: Drag-drop "Confirmée" → "En préparation"
    UI->>API: POST /api/orders/1057/status<br/>{ status: "preparing", notes: "Démarrage cuisson" }
    API->>G: @Roles('admin','manager','employee')
    G-->>API: ok (role=employee)

    API->>OS: updateStatus(orderId=1057, "preparing", notes)
    OS->>DB: SELECT Order WHERE id=1057
    DB-->>OS: Order { status:'confirmed' }

    OS->>FSM: canTransition('confirmed', 'preparing') ?
    FSM-->>OS: ✅ valide

    OS->>DB: BEGIN
    OS->>DB: UPDATE Order SET status='preparing',<br/>updated_at=NOW WHERE id=1057
    OS->>DB: INSERT OrderStatusHistory<br/>(order_id, old='confirmed', new='preparing', notes)
    OS->>DB: COMMIT

    OS->>N: notify(userId=42, type='ORDER_STATUS',<br/>title='Préparation', body='Votre commande est en cuisine')
    N->>DB: INSERT Notification (user_id=42, type, ...)
    N->>SSE: emit('notification', { userId:42, ... })
    SSE-->>C: 🔔 "Votre commande passe en préparation"

    OS-->>API: { success:true, order, history }
    API-->>UI: 200 OK
    UI-->>K: Carte déplacée + toast "Statut mis à jour"
```

### Machine d'états des statuts

```mermaid
stateDiagram-v2
    [*] --> pending
    pending --> confirmed: admin/employee accepte
    pending --> cancelled: client annule (avant validation)
    confirmed --> preparing: démarrage cuisson
    preparing --> cooking
    cooking --> assembling
    assembling --> ready: prêt pour livraison
    ready --> delivery: livreur assigné
    delivery --> delivered: preuve photo
    confirmed --> cancelled: employé annule avec motif
    delivered --> [*]
    cancelled --> [*]
```

### Points techniques
- **FSM côté service** : transitions interdites (ex. `delivered → pending`) rejetées avec 400.
- **Audit immuable** : `OrderStatusHistory` n'est jamais modifié, seulement complété.
- **Notif temps réel** : SSE pour push instantané sur le dashboard client.
- **Transaction** : statut + historique commités ensemble (`BEGIN/COMMIT`).
- **RBAC** : seuls `admin`, `manager`, `employee` peuvent faire avancer un statut.

---

## Scénario 4 — Un admin modère un avis

### Contexte
José, l'admin propriétaire, reçoit une notification : un nouvel avis est en attente de modération. C'est un avis 5 étoiles avec une photo. Il l'approuve depuis l'interface d'administration. Si l'avis était problématique (langage inapproprié), il le rejetterait avec un motif et l'auteur recevrait une notification.

### Déroulement métier
1. José ouvre l'écran *Modération* dans l'admin.
2. Le backend liste les `Publish` avec `status='pending'`.
3. José clique *Approuver* sur l'avis #312.
4. Le backend met à jour le statut, trace le modérateur, et l'avis devient public sur le site.
5. Si rejet : statut `rejected`, motif enregistré, client notifié.

### Diagramme

```mermaid
sequenceDiagram
    autonumber
    actor J as José (admin)
    actor C as Client (auteur)
    participant UI as Admin Panel
    participant API as NestJS API
    participant G as RolesGuard
    participant PS as PublishService
    participant DB as PostgreSQL
    participant Cache as Redis cache
    participant N as NotificationService

    J->>UI: Ouvre "Avis en attente"
    UI->>API: GET /api/publish?status=pending&limit=20
    API->>G: @Roles('admin','superadmin')
    G-->>API: ok
    API->>DB: SELECT Publish WHERE status='pending'<br/>JOIN User, Order, ReviewImage<br/>ORDER BY created_at DESC LIMIT 20
    DB-->>API: [Publish #312, ...]
    API-->>UI: liste paginée

    J->>UI: Clique "Approuver" #312
    UI->>API: PATCH /api/publish/312/moderate { action: "approve" }
    API->>PS: moderate(id=312, by=J.id, action='approve')
    PS->>DB: SELECT Publish WHERE id=312
    DB-->>PS: Publish { status:'pending', user_id:42 }

    PS->>DB: BEGIN
    PS->>DB: UPDATE Publish SET status='approved',<br/>moderated_by=:adminId, moderated_at=NOW<br/>WHERE id=312
    PS->>DB: COMMIT

    PS->>Cache: INVALIDATE "reviews:public:*"
    PS->>N: notify(userId=42, type='REVIEW_APPROVED',<br/>title='Votre avis est publié')
    N->>DB: INSERT Notification

    PS-->>API: { success:true, publish }
    API-->>UI: 200 OK
    UI-->>J: Carte retirée, toast "Avis approuvé"

    %% Alternative — rejet
    Note over J,N: Variante : rejet
    J->>UI: Clique "Rejeter" + saisit motif
    UI->>API: PATCH /api/publish/312/moderate<br/>{ action:"reject", reason:"langage inapproprié" }
    API->>PS: moderate(...)
    PS->>DB: UPDATE Publish SET status='rejected', moderated_by, moderated_at
    PS->>N: notify(userId=42, type='REVIEW_REJECTED', body=reason)
    N-->>C: 🔔 "Votre avis n'a pas été publié : langage inapproprié"
```

### Points techniques
- **Traçabilité** : `moderated_by` + `moderated_at` sont obligatoires (qui a décidé, quand).
- **Cache** : la liste publique des avis est cachée — l'approbation invalide la clé pour rafraîchir le site.
- **Transparence** : en cas de rejet, le client est notifié avec le motif (conformité éditoriale).
- **Visibilité conditionnelle** : seul `Publish.status='approved'` est servi sur les pages publiques (filtre côté repo).
- **RBAC strict** : route protégée par `@Roles('admin','superadmin')`.

---

## Annexe — Conventions communes aux 4 séquences

| Élément | Convention | Implémentation |
|---|---|---|
| Authentification | Bearer JWT dans l'en-tête `Authorization` | `JwtAuthGuard` global |
| Validation entrée | DTO + `class-validator` | `CustomValidationPipe` (`whitelist:true`, `forbidNonWhitelisted:true`) |
| Permissions | Décorateur `@Roles(...)` | `RolesGuard` après JWT |
| Transactions | `BEGIN ... COMMIT` Prisma | `prisma.$transaction([...])` |
| Audit hors-bande | MongoDB collection `audit_logs` | Écriture *fire-and-forget* après le commit SQL |
| Notifications | Persistance + push temps réel | Table `Notification` + canal SSE/WebSocket |
| Réponse API | Wrapper uniforme | `TransformInterceptor` → `{ success, data, ... }` |
| Erreurs | Filtre global | `AllExceptionsFilter` → JSON `{ statusCode, message, error, path, timestamp }` |
