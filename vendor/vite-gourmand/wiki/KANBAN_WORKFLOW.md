# 📋 Système Kanban & Suivi Temps Réel - Guide Complet

## 🎯 Vue d'Ensemble

Le système de gestion des commandes de Vite & Gourmand utilise une **vue Kanban** pour les employés/admins et un **suivi en temps réel avec animations SVG** pour les clients.

---

## 🔄 Workflow Complet

### 1. Client (Julie) passe commande
- Sélectionne un menu
- Remplit le formulaire
- Commande créée avec statut **"pending"**

### 2. Employé/Admin voit la commande
- Apparaît dans la colonne **"Confirmées"** du Kanban
- Informations visibles :
  - Priorité (🚨 Urgent, ⚡ Prioritaire, 📌 Normal, 📋 Faible)
  - Nombre de personnes
  - Date et heure de livraison
  - Ville de livraison
  - Demandes spéciales
  - Équipement requis

### 3. Pierre (employé) prend en charge
- Clique sur **"Passer à l'étape suivante"**
- La commande avance automatiquement

### 4. Progression des statuts

```
pending          → confirmed        → initiated         → prep_ingredients
En attente         Confirmée          Initiée             Préparation

→ assembly        → cooking          → packaging         → delivery
  Assemblage        Cuisson            Emballage           Livraison

→ delivered       → completed
  Livré             Terminé
```

### 5. Client voit en temps réel
- Animation SVG change selon l'étape
- Barre de progression mise à jour
- Historique détaillé avec timestamps
- Nom de l'employé assigné

---

## 📊 Vue Kanban (Employés/Admins)

### Layout

Le Kanban affiche **7 colonnes** :

1. ✅ **Confirmées** (confirmed) - Bleu
2. 🚀 **Initiées** (initiated) - Violet
3. 🔪 **Préparation** (prep_ingredients) - Jaune
4. 🍽️ **Assemblage** (assembly) - Orange
5. 🔥 **Cuisson** (cooking) - Rouge
6. 📦 **Emballage** (packaging) - Vert
7. 🚚 **Livraison** (delivery) - Indigo

### Statistiques en Haut

```
┌─────────────┬─────────────┬─────────────┬─────────────┐
│ À initier   │ En production│ Urgentes    │ Mes commandes│
│     3       │      8       │     2       │      5       │
└─────────────┴─────────────┴─────────────┴─────────────┘
```

### Cartes de Commande

Chaque carte affiche :
- **Badge de priorité** (couleur + icône)
- **Badge équipement** (si applicable)
- **Titre du menu**
- **Client** (nom)
- **Nombre de personnes**
- **Date et heure de livraison**
- **Ville**
- **Chef assigné** (si assigné)
- **Demandes spéciales** (si présentes)
- **Temps restant estimé**
- **Bouton "Passer à l'étape suivante"**

### Tri Automatique

Les commandes sont triées par :
1. **Priorité** : Urgent → High → Medium → Low
2. **Date de livraison** : Plus proche → Plus lointaine

### Gestion Intelligente

- ⚡ **Cuisson automatiquement ignorée** si `cookingRequired = false`
- 🎯 **Ring rouge** sur les commandes urgentes (< 24h)
- 🔧 **Badge équipement** si `equipmentStatus !== 'not_applicable'`

---

## 📱 Suivi Client (Temps Réel)

### Page de Suivi

Accessible via **"📍 Voir le suivi en temps réel"** depuis "Mon Espace"

### Éléments Affichés

#### 1. Alerte Équipement (si applicable)
```
⏰ Retour d'équipement bientôt dû
L'équipement prêté doit être retourné avant le [DATE]
Temps restant : 18 heures
⚠️ Passé ce délai, des frais de 600€ seront automatiquement facturés.
```

#### 2. Animation SVG Dynamique

Selon le statut :

**Préparation des ingrédients** 🔪
- Planche à découper animée
- Couteau en mouvement (bounce)
- Légumes qui pulsent

**Cuisson** 🔥
- Casserole
- Flammes animées (pulse)
- Vapeur qui monte (bounce)

**Emballage** 📦
- Boîte avec ruban
- Animation pulse
- Nœud décoratif

**Livraison** 🚚
- Camion en mouvement (bounce)
- Roues qui tournent
- Nuage de poussière

**Livré** ✅
- Maison
- Checkmark vert animé (pulse)

#### 3. Statut Actuel

- Badge coloré avec libellé
- Description textuelle
- Barre de progression (0-100%)
- Temps restant estimé

#### 4. Historique Détaillé

Timeline vertical avec :
- ✅ Icône verte pour l'étape actuelle
- ⚪ Icône grise pour les étapes passées
- Date et heure précise
- Nom de l'employé
- Notes (si présentes)

#### 5. Informations Équipement

Si équipement prêté :
- Statut actuel
- Date limite de retour
- Avertissement pénalité (600€)
- Confirmation de retour (si retourné)

---

## 🎨 Animations SVG

### Liste Complète

| Statut | Animation | Éléments |
|--------|-----------|----------|
| **pending/confirmed** | Toque de chef | Pulse |
| **initiated** | Toque de chef | Pulse |
| **prep_ingredients** | Couteau + légumes | Bounce + Pulse |
| **assembly** | Assiettes | Slide |
| **cooking** | Casserole + flammes | Pulse |
| **packaging** | Boîte + ruban | Pulse |
| **delivery** | Camion | Bounce |
| **delivered** | Maison + check | Pulse |

### Classes Tailwind Utilisées

```css
animate-bounce      /* Rebond doux */
animate-pulse       /* Pulsation */
animate-[bounce...] /* Animations personnalisées */
```

---

## 🔧 Système d'Équipement

### Quand est-ce requis ?

Équipement requis si :
- **Nombre de personnes ≥ 20**

### Types d'Équipement

- Chafing dishes (réchauds)
- Plateaux de service
- Couverts de service
- Nappes et serviettes

### Statuts d'Équipement

```
not_applicable   → pending        → delivered      → returned
Pas d'équipement   En attente       Livré             Retourné

                                  → late           → charged
                                     En retard        Facturé 600€
```

### Timeline

1. **Livraison** : Équipement livré avec la commande
2. **Deadline** : +2 jours après livraison
3. **Alerte** : 12h avant la deadline
4. **Pénalité** : 600€ si non retourné

### Notifications Client

**12h avant deadline** :
```
⏰ Retour d'équipement bientôt dû
Temps restant : 12 heures
⚠️ Pénalité : 600€
```

**Après deadline** :
```
❌ Équipement non retourné
💰 Facturé : 600€
```

---

## 📈 Priorités Automatiques

### Calcul de la Priorité

```javascript
const daysUntilDelivery = (deliveryDate - now) / (1000 * 60 * 60 * 24);

if (daysUntilDelivery === 0) priority = 'urgent';      // 🚨 URGENT
else if (daysUntilDelivery === 1) priority = 'high';   // ⚡ Prioritaire
else if (daysUntilDelivery > 4) priority = 'low';      // 📋 Faible
else priority = 'medium';                               // 📌 Normal
```

### Affichage Visuel

- **🚨 URGENT** : Badge rouge, ring rouge sur la carte
- **⚡ Prioritaire** : Badge orange
- **📌 Normal** : Badge jaune
- **📋 Faible** : Badge gris

---

## 💡 Fonctionnalités Avancées

### 1. Estimation de Temps

Calcul intelligent selon :
- Statut actuel (% complétion)
- Temps jusqu'à la livraison
- Nombre de personnes

Affichage :
- `< 24h` : "Environ Xh restantes"
- `≥ 24h` : "Environ X jours restants"

### 2. Métadonnées Commande

Chaque commande inclut :
- `priority` : Calculé automatiquement
- `assignedTo` : ID de l'employé
- `assignedToName` : Nom complet
- `cookingRequired` : Boolean
- `estimatedCompletionTime` : String
- `statusHistory` : Array d'entrées

### 3. Historique Complet

Chaque changement de statut enregistre :
```javascript
{
  status: "Préparation des ingrédients",
  date: "2026-02-03T10:30:00Z",
  employeeName: "Pierre Laurent",
  notes: "Début de la préparation"
}
```

---

## 🎮 Utilisation Pratique

### Scénario Complet

#### Étape 1 : Julie commande (Client)

1. Va sur "Nos Menus"
2. Choisit "Menu Gourmand"
3. Remplit : 25 personnes, livraison dans 2 jours
4. Ajoute : "Options végétariennes pour 3 personnes"
5. Confirme

➡️ **Résultat** : Commande créée avec priorité "high"

#### Étape 2 : Pierre voit (Employé)

1. Se connecte
2. Va dans "Administration" → Onglet "📋 Kanban"
3. Voit la commande dans **"Confirmées"**
4. Remarque : Badge "⚡ Prioritaire" + Badge "🔧 Équipement"
5. Clique **"Passer à l'étape suivante"**

➡️ **Résultat** : Commande passe à "Initiée"

#### Étape 3 : Production (Pierre continue)

1. Clique encore : **"Initiée"** → **"Préparation"**
2. Clique encore : **"Préparation"** → **"Assemblage"**
3. Clique encore : **"Assemblage"** → **"Cuisson"**
   (Si pas de cuisson : saute directement à "Emballage")
4. Clique encore : **"Cuisson"** → **"Emballage"**
5. Clique encore : **"Emballage"** → **"Livraison"**

#### Étape 4 : Julie suit (Client)

À chaque étape, Julie voit dans "Mon Espace" → "Voir le suivi" :

1. **Animation change** (couteau → casserole → boîte → camion)
2. **Barre de progression** avance
3. **Historique s'allonge** avec timestamps
4. **Nom de Pierre** apparaît sur chaque étape

#### Étape 5 : Livraison

1. Pierre clique : **"Livraison"** → **"Livré"**
2. Julie voit :
   - ✅ Animation "Maison + check"
   - Barre à 100%
   - ⏰ Alerte équipement : "À retourner avant le [DATE+2j]"

#### Étape 6 : Retour Équipement

- **Cas 1** : Julie retourne dans les 2 jours
  → ✅ Statut "completed", pas de frais

- **Cas 2** : Julie ne retourne pas
  → ❌ Après 2 jours : 600€ facturés automatiquement
  → Statut "late_equipment"

---

## 📊 Données de Simulation

### 13 Commandes Pré-chargées

1. **Commande de Julie** (demo-user-001)
   - Menu Gourmand, 25 pers
   - Statut : `prep_ingredients`
   - Priorité : `high`
   - Assignée à : Pierre Laurent

2-13. **12 Autres Commandes**
   - Différents menus
   - Différents statuts (confirmées → livraison)
   - Différentes priorités
   - Différents clients
   - Certaines avec équipement

### Répartition par Statut

- **2 commandes** en "Confirmées"
- **2 commandes** en "Initiées"
- **2 commandes** en "Préparation"
- **2 commandes** en "Assemblage"
- **1 commande** en "Cuisson"
- **2 commandes** en "Emballage"
- **2 commandes** en "Livraison"

---

## 🎯 Avantages du Système

### Pour les Employés

✅ **Vue d'ensemble claire** : Toutes les commandes sur un seul écran

✅ **Priorisation automatique** : Les urgences en premier

✅ **Workflow simplifié** : Un clic = une étape

✅ **Pas d'erreurs** : Impossible de sauter une étape

✅ **Traçabilité** : Historique complet de chaque action

### Pour les Clients

✅ **Transparence totale** : Savoir exactement où en est la commande

✅ **Animations engageantes** : SVG dynamiques et modernes

✅ **Temps réel** : Mise à jour instantanée

✅ **Confiance renforcée** : Voir le nom du chef qui s'occupe de la commande

✅ **Pas de surprise** : Alertes équipement claires

---

## 🔮 Évolutions Futures

### Version 2.0 (Planifiée)

- [ ] Drag & drop des cartes entre colonnes
- [ ] Filtres avancés (client, menu, ville, priorité)
- [ ] Recherche en temps réel
- [ ] Export PDF du suivi de commande
- [ ] Notifications push (mobile)

### Version 3.0 (Future)

- [ ] Chat client ↔ employé dans le suivi
- [ ] Photos de la préparation
- [ ] Vidéo en direct de la livraison
- [ ] Signature électronique à la livraison
- [ ] QR code pour retour d'équipement

---

## 📝 Résumé

Le système Kanban + Suivi Temps Réel offre :

- **7 étapes de production** claires et visuelles
- **Animations SVG** pour chaque étape
- **Priorités automatiques** selon l'urgence
- **Gestion d'équipement** avec chrono et pénalité
- **Traçabilité complète** avec historique
- **Transparence client** totale

**🎉 Résultat** : Une expérience utilisateur exceptionnelle qui rassure les clients et facilite le travail des équipes !

---

**💪 Testez dès maintenant en mode démo !**

1. Connectez-vous en tant que **Pierre** (employé)
2. Allez dans "Administration" → "📋 Kanban"
3. Faites avancer les commandes
4. Déconnectez-vous
5. Connectez-vous en tant que **Julie** (cliente)
6. Allez dans "Mon Espace" → "📍 Voir le suivi"
7. **Admirez la magie !** ✨
