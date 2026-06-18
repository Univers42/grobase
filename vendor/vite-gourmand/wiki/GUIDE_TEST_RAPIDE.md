# 🚀 Guide de Test Rapide - Système Kanban

## 🎯 Objectif
Tester le système de suivi temps réel des commandes avec simulation interactive entre Julie (cliente) et Pierre (employé).

---

## 📋 Scénario de Test Complet

### ÉTAPE 1️⃣ : Connexion Employé (Pierre)

1. **Cliquez sur** `Accès Employé` sur la page de démo
2. **Vous êtes connecté en tant que** : Pierre Laurent (employé)
3. **Allez dans** : `Administration` (barre de navigation)

### ÉTAPE 2️⃣ : Vue Kanban

4. **Cliquez sur l'onglet** : `📋 Kanban`
5. **Observez** :
   - 7 colonnes de production
   - Statistiques en haut (À initier, En production, Urgentes, Mes commandes)
   - 12+ commandes réparties dans les colonnes
   - Badges de priorité colorés (🚨 URGENT, ⚡ Prioritaire, etc.)

### ÉTAPE 3️⃣ : Trouver la Commande de Julie

6. **Cherchez dans la colonne jaune** `🔪 Préparation`
7. **Trouvez la carte** :
   ```
   ⚡ Prioritaire    🔧 Équipement
   Menu Gourmand
   👤 Julie Dubois
   🍽️ 25 personnes
   📅 [Date] à 19:00
   📍 Bordeaux
   👨‍🍳 Pierre Laurent
   ```

### ÉTAPE 4️⃣ : Faire Progresser la Commande

8. **Cliquez sur** : `Passer à l'étape suivante` (sur la carte de Julie)
9. **La commande bouge** : `Préparation` → `Assemblage`
10. **Cliquez encore** : `Assemblage` → `Cuisson`
11. **Cliquez encore** : `Cuisson` → `Emballage`
12. **Cliquez encore** : `Emballage` → `Livraison`

**Notez** : Chaque clic enregistre un historique avec votre nom et l'heure exacte !

### ÉTAPE 5️⃣ : Déconnexion

13. **Cliquez sur** : `Se déconnecter` (en haut à droite)
14. **Retournez à** : Page de sélection de rôles

### ÉTAPE 6️⃣ : Connexion Cliente (Julie)

15. **Cliquez sur** : `Accès Utilisateur`
16. **Vous êtes connecté en tant que** : Julie Dubois (cliente)
17. **Allez dans** : `Mon Espace` (barre de navigation)

### ÉTAPE 7️⃣ : Voir le Suivi Temps Réel

18. **Vous voyez la liste de vos commandes**
19. **Trouvez** : Menu Gourmand (25 personnes)
20. **Cliquez sur** : `📍 Voir le suivi en temps réel`

### ÉTAPE 8️⃣ : Admirer la Magie ✨

21. **Observez l'animation SVG** :
   - Si en "Livraison" : Camion animé 🚚 qui bounce
   - Si en "Emballage" : Boîte avec ruban 📦 qui pulse
   - Si en "Cuisson" : Casserole avec flammes 🔥

22. **Regardez les détails** :
   - Badge coloré du statut actuel
   - Barre de progression (ex: 95%)
   - Description de l'étape
   - Estimation du temps restant

23. **Scrollez vers le bas** :
   - **Historique détaillé** avec timeline
   - Chaque étape avec date/heure
   - **Nom de Pierre** sur chaque action
   - Notes spécifiques

24. **Vérifiez l'alerte équipement** (en haut) :
   ```
   ⏰ Retour d'équipement bientôt dû
   L'équipement prêté doit être retourné avant le [DATE]
   Temps restant : X heures
   ⚠️ Passé ce délai, des frais de 600€ seront facturés.
   ```

---

## 🎨 Ce que Vous Devriez Voir

### Vue Employé (Kanban)
```
┌──────────────────────────────────────────────────────┐
│  À initier │ En production │ Urgentes │ Mes commandes │
│      2     │       8       │     2    │      5        │
└──────────────────────────────────────────────────────┘

✅ Confirmées  🚀 Initiées  🔪 Préparation  🍽️ Assemblage
[2 cartes]    [1 carte]    [2 cartes]     [2 cartes]

🔥 Cuisson    📦 Emballage  🚚 Livraison
[1 carte]    [2 cartes]    [2 cartes]
```

### Vue Cliente (Suivi)
```
┌──────────────────────────────────┐
│  Animation SVG (🚚 camion)       │
│                                  │
│  🚚 En livraison                 │
│  Votre commande est en route !   │
│                                  │
│  ███████████████████░░░ 95%      │
│                                  │
│  ⏰ Environ 4h restantes         │
└──────────────────────────────────┘

📜 Historique détaillé
  ✅ En cours de livraison
     03/02/2026 14:30
     👨‍🍳 Pierre Laurent
  
  ○ Emballage
     03/02/2026 13:45
     👨‍🍳 Pierre Laurent
  
  ○ Cuisson
     03/02/2026 12:00
     👨‍🍳 Pierre Laurent
```

---

## 🔍 Points de Vérification

### ✅ Checklist Technique

- [ ] Les commandes apparaissent dans le Kanban
- [ ] Les statistiques en haut sont correctes
- [ ] Le bouton "Passer à l'étape suivante" fonctionne
- [ ] La commande change de colonne
- [ ] Un toast de confirmation apparaît
- [ ] L'historique est mis à jour avec le nom de Pierre

- [ ] La vue client affiche la commande de Julie
- [ ] Le bouton "Voir le suivi" fonctionne
- [ ] L'animation SVG correspond au statut
- [ ] La barre de progression est correcte
- [ ] L'historique affiche toutes les étapes
- [ ] Le nom de Pierre apparaît dans l'historique
- [ ] L'alerte équipement est visible (si 25 pers)

---

## 🎭 Tests Avancés

### Test 1 : Commande Sans Cuisson

1. **Trouvez une commande** : "Menu Apéritif" (pas de cuisson requise)
2. **Faites-la progresser** : Assemblage → Emballage (saute la cuisson)
3. **Vérifiez** : Badge vert "✓ Pas de cuisson requise"

### Test 2 : Commandes Urgentes

1. **Cherchez le ring rouge** autour d'une carte
2. **Vérifiez le badge** : "🚨 URGENT"
3. **Confirmez** : Livraison < 24h

### Test 3 : Équipement

1. **Cherchez** : Badge "🔧 Équipement"
2. **Vérifiez** : Nombre de personnes ≥ 20
3. **Côté client** : Alerte équipement visible

### Test 4 : Statistiques Temps Réel

1. **Notez les stats** en haut du Kanban
2. **Faites avancer une commande**
3. **Vérifiez** : Stats mises à jour automatiquement

---

## 🐛 Troubleshooting

### Problème : Les commandes n'apparaissent pas

**Solution** :
- Vérifiez que vous êtes en mode démo (banner jaune en haut)
- Rechargez la page
- Vérifiez que vous avez cliqué sur "Accès Employé"

### Problème : Animation SVG ne s'affiche pas

**Solution** :
- Scrollez vers le haut dans la modal de suivi
- Attendez 1-2 secondes pour le chargement
- Vérifiez que le statut n'est pas "pending"

### Problème : Le bouton ne fait rien

**Solution** :
- Vérifiez la console navigateur (F12)
- Attendez que le toast apparaisse
- Rechargez l'onglet Kanban

---

## 📊 Données Disponibles

### Commandes Pré-chargées

**Commande de Julie** (pour le test principal)
- ID : `order-julie-demo`
- Menu : Menu Gourmand
- Personnes : 25
- Statut initial : `prep_ingredients`
- Priorité : `high`
- Équipement : Oui

**12 Autres Commandes**
- Réparties sur tous les statuts
- Différents menus et clients
- Priorités variées
- Certaines avec équipement

### Employés

1. **Pierre Laurent** (demo-employee-001)
2. Marie Durand (employee-002)
3. Antoine Mercier (employee-003)

---

## 🎯 Résultats Attendus

Après ce test complet, vous devriez :

✅ **Comprendre le workflow** de production
✅ **Voir la transparence** totale pour le client
✅ **Apprécier les animations** SVG
✅ **Observer le temps réel** du suivi
✅ **Constater la traçabilité** (historique)
✅ **Identifier le système d'équipement**

---

## 💡 Cas d'Usage Réels

Ce système permet à **Vite & Gourmand** de :

1. **Rassurer les clients** : Ils savent où en est leur commande
2. **Organiser la production** : Vue claire pour l'équipe
3. **Prioriser intelligemment** : Urgences en tête
4. **Tracer les responsabilités** : Qui fait quoi et quand
5. **Gérer l'équipement** : Pas de perte avec le chrono
6. **Améliorer l'expérience** : Animations modernes et engageantes

---

## 🚀 Prochaines Étapes

Une fois le test validé, vous pouvez :

1. **Personnaliser les animations** SVG
2. **Ajuster les délais** d'alerte équipement
3. **Modifier les priorités** automatiques
4. **Ajouter des étapes** de production
5. **Intégrer des notifications** push
6. **Connecter au vrai backend** (remplacer isDemoMode)

---

**🎉 Bon Test !**

Si tout fonctionne, vous avez un système de gestion de commandes de niveau professionnel, digne d'une grande plateforme comme Uber Eats ou Deliveroo !

**Questions ?** Consultez le [KANBAN_WORKFLOW.md](./KANBAN_WORKFLOW.md) pour plus de détails.
