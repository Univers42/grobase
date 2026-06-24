# ⚡ Démarrage Rapide - Vite & Gourmand

## 🚀 Lancer l'Application

1. **Ouvrez l'application** dans votre navigateur
2. Vous arrivez automatiquement sur la **page de sélection de rôle**

---

## 🎯 3 Boutons - 3 Rôles

### 👑 Accès Admin
**Cliquez sur "Accéder en tant qu'Administrateur"**

Vous êtes maintenant : **José Martinez** (Administrateur)

**Ce que vous pouvez faire :**
- 📊 Voir le dashboard avec statistiques
- 📋 Gérer tous les menus
- 🛒 Gérer toutes les commandes
- 👥 Créer des employés
- 🎨 Consulter la charte graphique
- ⭐ Valider les avis clients

---

### 👔 Accès Employé
**Cliquez sur "Accéder en tant qu'Employé"**

Vous êtes maintenant : **Pierre Laurent** (Employé)

**Ce que vous pouvez faire :**
- 📋 Gérer les menus
- 🛒 Gérer les commandes
- ⭐ Valider les avis
- 📞 Contacter les clients

**Ce que vous NE pouvez PAS faire :**
- ❌ Voir le dashboard analytics
- ❌ Créer des employés
- ❌ Consulter les logs système

---

### 👤 Accès Client
**Cliquez sur "Accéder en tant qu'Utilisateur"**

Vous êtes maintenant : **Julie Dubois** (Cliente)

**Ce que vous pouvez faire :**
- 🍽️ Voir les menus disponibles
- 🛒 Passer commande
- 📦 Suivre mes commandes
- ❌ Annuler (si en attente)
- ⭐ Laisser un avis
- ✏️ Modifier mon profil

**Ce que vous NE pouvez PAS faire :**
- ❌ Gérer les menus
- ❌ Voir les autres commandes
- ❌ Accéder à l'administration

---

## 🔄 Changer de Rôle

À tout moment, vous pouvez :

1. Cliquer sur le **bouton utilisateur** (👤 en haut à droite)
2. Sélectionner **"Déconnexion"**
3. Vous revenez à la page de sélection
4. Choisir un autre rôle

---

## 🎨 Indicateurs Visuels

### Banner Orange/Violet
En haut de toutes les pages, vous voyez :
```
🎯 Mode Démonstration • Vous explorez en tant que [Nom] ([Rôle])
```

### Badge de Rôle (Navbar)
Un badge coloré à droite :
- 🟣 Violet = Admin
- 🟠 Orange = Employé  
- 🔵 Bleu = Client

---

## 📋 Parcours Recommandés

### 🏃 Parcours Rapide (5 min)

1. **Admin** (2 min)
   - Voir le dashboard
   - Consulter les stats

2. **Employé** (2 min)
   - Créer un menu
   - Accepter une commande

3. **Client** (1 min)
   - Explorer les menus
   - Voir mes commandes

---

### 🚶 Parcours Complet (15 min)

#### 👑 En tant qu'Admin (5 min)
1. Ouvrir le dashboard
2. Analyser les graphiques
3. Aller dans "Menus" → Créer un menu
4. Aller dans "Commandes" → Filtrer par statut
5. Aller dans "Avis" → Valider un avis
6. Cliquer sur "Charte Graphique"

#### 👔 En tant qu'Employé (5 min)
1. Se déconnecter
2. Se connecter en Employé
3. Aller dans "Menus" → Modifier un menu
4. Aller dans "Commandes" → Changer un statut
5. Aller dans "Avis" → Rejeter un avis

#### 👤 En tant que Client (5 min)
1. Se déconnecter
2. Se connecter en Client
3. Aller dans "Nos Menus"
4. Cliquer sur un menu → "Commander"
5. Remplir le formulaire de commande
6. Aller dans "Mon Espace"
7. Voir mes commandes
8. Cliquer sur "Annuler" (si en attente)

---

## 💡 Astuces

### 🎯 Mode Démo = Zéro Configuration
- ✅ Pas de backend requis
- ✅ Pas de compte à créer
- ✅ Accès instantané
- ✅ Toutes les fonctionnalités disponibles

### 📊 Données Pré-chargées
- 3 menus déjà créés
- 2 commandes existantes
- 3 avis validés

### 🔐 Contrôle d'Accès Réel
Même en démo, les permissions sont respectées :
- Un client ne voit PAS le dashboard
- Un employé ne peut PAS créer d'employés
- Un admin voit TOUT

---

## 🎓 Pour Aller Plus Loin

### Documentation Complète
- 📖 [DEMO_MODE.md](./DEMO_MODE.md) - Guide détaillé du mode démo
- 📖 [README.md](./README.md) - Documentation générale
- 📖 [ARCHITECTURE.md](./ARCHITECTURE.md) - Architecture technique
- 📖 [API_DOCUMENTATION.md](./API_DOCUMENTATION.md) - Endpoints API

### Fonctionnalités Avancées
- Système de livraison intelligent (gratuit à Bordeaux)
- Réduction automatique de 10% (5+ personnes)
- Suivi de commande en temps réel
- Historique des statuts
- Dashboard analytics avec graphiques

---

## ❓ FAQ

**Q : Les données sont-elles sauvegardées ?**  
R : Non, le mode démo utilise des données locales. Elles sont réinitialisées au rechargement de la page.

**Q : Puis-je tester toutes les fonctionnalités ?**  
R : Oui ! Toutes les fonctionnalités UI sont disponibles et testables.

**Q : Comment passer en mode production ?**  
R : Voir le fichier [DEMO_MODE.md](./DEMO_MODE.md) section "Passer en Mode Production".

**Q : Puis-je créer de vraies commandes ?**  
R : En mode démo, les commandes sont simulées. Pour de vraies commandes, il faut activer le backend.

**Q : Les emails sont-ils envoyés ?**  
R : Non, en mode démo les emails sont simulés (console.log).

---

## 📞 Support

Besoin d'aide ? Consultez :
- 📖 La documentation complète
- 🎨 La charte graphique (Admin)
- 💬 Les fichiers README

---

**🎉 Bon test de Vite & Gourmand !**

*Simple. Rapide. Complet.*
