# ❓ Aide & Support - Vite & Gourmand

## 🆘 Problèmes Courants

### L'application ne démarre pas

**Solution** : Vérifiez que vous utilisez un navigateur moderne (Chrome, Firefox, Safari, Edge)

---

### Je ne vois pas le dashboard

**Cause** : Vous n'êtes pas connecté en tant qu'Administrateur

**Solution** :
1. Déconnectez-vous
2. Sélectionnez "Accès Administrateur"
3. Le dashboard apparaît dans l'onglet "📊 Dashboard"

---

### Je ne peux pas créer d'employé

**Cause** : Seuls les administrateurs peuvent créer des employés

**Solution** : Connectez-vous en tant qu'Administrateur

---

### Les données ne sont pas sauvegardées

**C'est normal !** Le mode démo ne sauvegarde pas les données.

**Explication** : Le mode démo utilise des données locales qui se réinitialisent au rechargement.

**Pour sauvegarder** : Passez en mode production (voir DEMO_MODE.md)

---

### Je ne trouve pas la charte graphique

**Accès** : Espace Administrateur → Bouton "Charte Graphique" (en haut à droite)

**Ou** : Menu "Admin" → Onglet dédié (si implémenté)

---

### Comment annuler une commande ?

**En tant que Client** :
1. Aller dans "Mon Espace"
2. Cliquer sur la commande
3. Bouton "Annuler" (uniquement si statut = "En attente")

**En tant qu'Employé/Admin** :
1. Aller dans "Commandes"
2. Sélectionner la commande
3. Changer le statut → "Annulée"
4. Indiquer le motif + mode de contact

---

### Les frais de livraison ne sont pas corrects

**Vérifiez** :
- Ville = "Bordeaux" → Livraison gratuite ✅
- Ville ≠ "Bordeaux" → 5€ + 0,59€/km

**Note** : Le calcul des km est estimatif en mode démo

---

### La réduction de 10% ne s'applique pas

**Conditions** :
- Nombre de personnes ≥ (Minimum du menu + 5)

**Exemple** :
- Menu minimum = 10 personnes
- Réduction à partir de 15 personnes
- Pour 12 personnes → Pas de réduction
- Pour 16 personnes → Réduction de 10%

---

### Je ne peux pas laisser d'avis

**Conditions** :
- Commande doit être status = "Terminée"
- Pas d'avis déjà soumis pour cette commande

**Solution** : En mode démo, changez le statut de la commande à "Terminée" (Admin/Employé)

---

## 📖 Documentation

### Démarrage
- **[QUICKSTART.md](./QUICKSTART.md)** - Démarrage rapide (5 min)
- **[DEMO_MODE.md](./DEMO_MODE.md)** - Guide du mode démo
- **[README.md](./README.md)** - Documentation générale

### Technique
- **[ARCHITECTURE.md](./ARCHITECTURE.md)** - Architecture du système
- **[API_DOCUMENTATION.md](./API_DOCUMENTATION.md)** - Endpoints API
- **[CONTRIBUTING.md](./CONTRIBUTING.md)** - Guide de contribution

### Référence
- **[COMPTES_DEMO.md](./COMPTES_DEMO.md)** - Identifiants et permissions
- **[CHANGELOG.md](./CHANGELOG.md)** - Historique des versions

---

## 🎓 Tutoriels

### Tutoriel 1 : Créer un menu (Admin/Employé)

1. Se connecter en tant qu'Admin ou Employé
2. Cliquer sur "Administration"
3. Onglet "Menus"
4. Bouton "Nouveau menu"
5. Remplir le formulaire :
   - Titre *
   - Description *
   - Prix (pour min personnes) *
   - Nombre minimum de personnes *
   - Thème, Régime, etc.
6. Ajouter des plats (optionnel)
7. Cliquer "Créer le menu"

---

### Tutoriel 2 : Passer une commande (Client)

1. Se connecter en tant qu'Utilisateur
2. Aller dans "Nos Menus"
3. Choisir un menu
4. Cliquer "Voir le détail"
5. Bouton "Commander ce menu"
6. Remplir le formulaire :
   - Nombre de personnes *
   - Adresse de livraison *
   - Ville *
   - Date et heure *
   - Demandes spéciales (optionnel)
7. Vérifier le prix total
8. Cliquer "Confirmer la commande"

---

### Tutoriel 3 : Gérer une commande (Admin/Employé)

1. Se connecter en tant qu'Admin ou Employé
2. Aller dans "Administration"
3. Onglet "Commandes"
4. Sélectionner une commande
5. Bouton "Modifier le statut"
6. Choisir le nouveau statut
7. Si annulation : indiquer motif + contact
8. Confirmer

**Statuts disponibles** :
- En attente → Accepté
- Accepté → En préparation
- En préparation → En cours de livraison
- En cours de livraison → Livré
- Livré → Terminé ou En attente du retour de matériel
- Tout statut → Annulé (avec motif)

---

### Tutoriel 4 : Valider un avis (Admin/Employé)

1. Se connecter en tant qu'Admin ou Employé
2. Aller dans "Administration"
3. Onglet "Avis"
4. Voir la liste des avis non validés
5. Lire l'avis
6. Choisir :
   - ✅ Valider (avis visible publiquement)
   - ❌ Rejeter (avis supprimé)
7. Confirmer l'action

---

## 🔑 Raccourcis Clavier

### Navigation
- **Accueil** : Logo en haut à gauche
- **Menus** : Menu "Nos Menus"
- **Contact** : Menu "Contact"

### Espace Utilisateur
- **Mon Espace** : Icône utilisateur → "Espace client"

### Administration
- **Admin Panel** : Bouton "Administration" (Admin/Employé)
- **Déconnexion** : Icône utilisateur → "Déconnexion"

---

## 🎨 Design & Accessibilité

### Palette de Couleurs

- **Orange Primary** : `#ea580c` - Actions principales
- **Orange Dark** : `#c2410c` - Hover states
- **Purple Admin** : `#9333ea` - Badge admin
- **Blue Client** : `#3b82f6` - Badge client

### Accessibilité

- ✅ Contraste WCAG AA respecté
- ✅ Navigation au clavier complète
- ✅ Labels explicites sur les formulaires
- ✅ Alt-text sur toutes les images

### Responsive

- ✅ Mobile (< 768px)
- ✅ Tablet (768px - 1024px)
- ✅ Desktop (> 1024px)

---

## 💡 Astuces & Bonnes Pratiques

### Pour Tester l'Application

1. **Commencez par le Client** pour comprendre le parcours utilisateur
2. **Passez à l'Employé** pour voir la gestion opérationnelle
3. **Terminez par l'Admin** pour voir la vue d'ensemble

### Pour Démontrer

1. **Préparez votre scénario** (voir DEMO_MODE.md)
2. **Utilisez le mode plein écran** (F11)
3. **Naviguez entre les rôles** pour montrer les différences
4. **Montrez le dashboard** pour impressionner

### Pour Développer

1. **Consultez ARCHITECTURE.md** pour comprendre le système
2. **Suivez CONTRIBUTING.md** pour les standards
3. **Utilisez TypeScript** pour éviter les erreurs
4. **Testez sur plusieurs rôles** avant de commit

---

## 🐛 Signaler un Bug

### Informations à Fournir

1. **Navigateur** : Chrome, Firefox, Safari, Edge + version
2. **OS** : Windows, Mac, Linux
3. **Rôle** : Admin, Employé, Client
4. **Page** : Où se produit le bug
5. **Étapes** : Comment reproduire
6. **Attendu** : Ce qui devrait se passer
7. **Réel** : Ce qui se passe
8. **Screenshot** : Si possible

### Exemple de Rapport

```markdown
**Navigateur** : Chrome 120
**OS** : Windows 11
**Rôle** : Client
**Page** : Commande

**Étapes** :
1. Aller sur "Nos Menus"
2. Sélectionner "Menu Gourmand"
3. Cliquer "Commander"
4. Remplir avec 15 personnes

**Attendu** : Réduction de 10% appliquée
**Réel** : Pas de réduction
**Screenshot** : [lien]
```

---

## 📞 Contact

### Support Technique
- 📧 Email : support@vite-gourmand.fr
- 💬 Discord : [Lien serveur]
- 🐛 GitHub Issues : [Lien repo]

### Documentation
- 📖 Docs officielles : [Lien]
- 🎥 Tutoriels vidéo : [Lien]
- 📝 Blog : [Lien]

### Réseaux Sociaux
- 🐦 Twitter : @ViteGourmand
- 📘 Facebook : /ViteGourmand
- 📷 Instagram : @vitegourmand

---

## ✅ Checklist de Dépannage

Avant de demander de l'aide, vérifiez :

- [ ] Navigateur moderne et à jour
- [ ] JavaScript activé
- [ ] Cookies activés
- [ ] Pas de bloqueur de publicités agressif
- [ ] Console développeur sans erreur rouge
- [ ] Bonne connexion internet (si mode production)
- [ ] Rôle correct pour la fonctionnalité
- [ ] Documentation consultée

---

**💪 Vous avez tout essayé ? Contactez-nous, on est là pour vous aider !**
