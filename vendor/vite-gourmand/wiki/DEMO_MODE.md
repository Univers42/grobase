# 🎯 Mode Démonstration - Guide d'Utilisation

## Démarrage Rapide

Au lancement de l'application, vous arrivez automatiquement sur la **page de sélection de rôle**.

### 3 Rôles Disponibles

Choisissez le rôle que vous souhaitez explorer :

---

## 👑 Administrateur (Super Admin)

**José Martinez** - `admin@demo.app`

### Accès Complet à Toutes les Fonctionnalités

✅ **Dashboard Analytics**
- Statistiques en temps réel
- Graphiques de chiffre d'affaires
- Top des menus les plus populaires
- KPIs principaux

✅ **Gestion des Menus**
- Créer, modifier, supprimer des menus
- Gestion des plats et catégories
- Upload d'images
- Gestion du stock

✅ **Gestion des Commandes**
- Voir toutes les commandes
- Mettre à jour les statuts
- Filtrer par statut/client
- Historique complet

✅ **Validation des Avis**
- Approuver ou rejeter les avis clients
- Modération du contenu

✅ **Gestion des Employés**
- Créer des comptes employés
- Désactiver des comptes
- Gestion des rôles

✅ **Charte Graphique**
- Accès au design system
- Palette de couleurs
- Guidelines UI/UX

✅ **Logs Système**
- Suivi des actions
- Analytics d'utilisation
- Audit trail

---

## 👔 Employé (Gestionnaire)

**Pierre Laurent** - `employee@demo.app`

### Accès Opérationnel

✅ **Gestion des Menus**
- Créer, modifier, supprimer des menus
- Gestion complète du catalogue

✅ **Gestion des Commandes**
- Voir toutes les commandes
- Mettre à jour les statuts
- Contact client obligatoire avant modification
- Filtres avancés

✅ **Validation des Avis**
- Approuver ou rejeter les avis clients

❌ **Pas d'accès à :**
- Dashboard analytics
- Gestion des employés
- Charte graphique
- Logs système

---

## 👤 Utilisateur (Client)

**Julie Dubois** - `user@demo.app`

### Accès Client Standard

✅ **Navigation**
- Consulter tous les menus disponibles
- Voir les détails des menus
- Filtres par thème, régime, prix

✅ **Commandes**
- Passer une nouvelle commande
- Calculateur automatique de prix
- Frais de livraison intelligents
  - Gratuit à Bordeaux
  - 5€ + 0,59€/km hors Bordeaux
- Réduction de 10% pour 5+ personnes

✅ **Espace Personnel**
- Voir toutes mes commandes
- Suivre le statut en temps réel
- Historique des statuts
- Annuler (si statut = en attente)

✅ **Profil**
- Modifier mes informations
- Changer mon adresse
- Mettre à jour mon téléphone

✅ **Avis**
- Laisser un avis après commande terminée
- Noter de 1 à 5 étoiles
- Ajouter un commentaire

❌ **Pas d'accès à :**
- Gestion des menus
- Gestion des commandes autres
- Administration

---

## 🔄 Changer de Rôle

Pour explorer un autre rôle :

1. Cliquez sur le **bouton utilisateur** (en haut à droite)
2. Sélectionnez **"Déconnexion"**
3. Vous revenez à la page de sélection
4. Choisissez un nouveau rôle

---

## 💾 Données de Démonstration

### Mode Hors Ligne

Le mode démo fonctionne **sans backend** :
- ✅ Toutes les données sont stockées localement
- ✅ Pas besoin de connexion serveur
- ✅ Instantané et rapide
- ✅ Aucun risque de perte de données

### Données Pré-chargées

#### 📋 Menus (3)
1. **Menu Gourmand** - Classique, 10 pers min, 450€
2. **Menu Vegan Délice** - Vegan, 8 pers min, 380€
3. **Menu Bordeaux Tradition** - Classique, 15 pers min, 520€

#### ⭐ Avis (3)
- Tous validés et visibles
- Notes de 4 à 5 étoiles

#### 🛒 Commandes (2)
- 1 commande acceptée (Julie)
- 1 commande en attente (Julie)

### Limitations du Mode Démo

❌ **Pas persistant** : Les données sont réinitialisées au rechargement de la page

❌ **Pas de notifications email** : Les emails sont simulés (console.log)

❌ **Pas de vraie authentification** : Pas de JWT tokens réels

✅ **Mais** : Toutes les fonctionnalités UI sont accessibles et testables !

---

## 🎨 Interface Utilisateur

### Indicateurs Visuels

#### Banner Mode Démo
En haut de la page, un banner orange/violet indique :
- 🎯 Mode Démonstration actif
- 👤 Rôle actuel (Admin, Employé, Client)
- 📧 Email de connexion

#### Badge Rôle (Navbar)
Un badge coloré dans la barre de navigation :
- 🟣 **Violet** = Administrateur
- 🟠 **Orange** = Employé
- 🔵 **Bleu** = Client

---

## 📊 Fonctionnalités Testables

### En tant qu'Admin

1. **Explorer le Dashboard**
   - Voir les graphiques
   - Analyser les KPIs
   - Consulter les statistiques

2. **Gérer les Menus**
   - Ajouter un nouveau menu
   - Modifier les prix
   - Changer les images

3. **Suivre les Commandes**
   - Changer les statuts
   - Filtrer par critères
   - Voir l'historique

4. **Consulter la Charte**
   - Design system complet
   - Palette de couleurs
   - Composants UI

### En tant qu'Employé

1. **Gérer les Menus**
   - CRUD complet
   - Upload d'images

2. **Traiter les Commandes**
   - Accepter/refuser
   - Mettre à jour les statuts
   - Contacter les clients

3. **Modérer les Avis**
   - Valider les bons avis
   - Rejeter les inappropriés

### En tant que Client

1. **Découvrir les Menus**
   - Filtrer par thème
   - Comparer les prix
   - Voir les détails

2. **Commander**
   - Sélectionner un menu
   - Remplir le formulaire
   - Voir le calcul automatique

3. **Suivre mes Commandes**
   - Statut en temps réel
   - Historique complet
   - Option d'annulation

4. **Laisser un Avis**
   - Noter l'expérience
   - Commenter le service

---

## 🔐 Sécurité en Mode Démo

### Contrôle d'Accès Simulé

Même en mode démo, les **contrôles de rôles sont actifs** :

- ❌ Un client ne peut **pas** accéder au dashboard admin
- ❌ Un employé ne peut **pas** créer d'autres employés
- ❌ Un utilisateur ne peut **pas** voir les commandes des autres

### Validation des Données

Toutes les validations sont actives :
- ✅ Formulaires validés
- ✅ Prix calculés correctement
- ✅ Dates vérifiées
- ✅ Stocks contrôlés

---

## 🚀 Passer en Mode Production

Pour utiliser l'application avec un vrai backend :

1. **Désactiver le mode démo** dans App.tsx :
   ```typescript
   const [isDemoMode, setIsDemoMode] = useState(false);
   ```

2. **Configurer Supabase** avec vos credentials

3. **Créer les comptes réels** via la route `/signup`

4. **Initialiser les données** avec `/init-data`

---

## 💡 Conseils d'Exploration

### Scénario 1 : Parcours Client Complet
1. Se connecter en tant que **Client**
2. Explorer les menus
3. Passer une commande
4. Consulter le suivi
5. Se déconnecter

### Scénario 2 : Workflow Employé
1. Se connecter en tant que **Employé**
2. Créer un nouveau menu
3. Voir les commandes en attente
4. Accepter une commande
5. Mettre à jour le statut

### Scénario 3 : Gestion Admin
1. Se connecter en tant que **Admin**
2. Consulter le dashboard
3. Analyser les statistiques
4. Valider des avis
5. Consulter la charte graphique

---

## 🎯 Objectif du Mode Démo

Ce mode permet de :

✅ **Tester** toutes les fonctionnalités sans backend
✅ **Explorer** les différents rôles et permissions
✅ **Comprendre** le workflow complet
✅ **Démontrer** les capacités de l'application
✅ **Former** les futurs utilisateurs

---

## 📞 Questions ?

Le mode démo est conçu pour être **intuitif et complet**. Si vous avez des questions :

- 📧 Consultez la documentation complète
- 💬 Explorez les différents rôles
- 🎨 Regardez la charte graphique

---

**🎉 Profitez de votre exploration de Vite & Gourmand !**

*Mode Démonstration - Données fictives - Fonctionnalités réelles*
