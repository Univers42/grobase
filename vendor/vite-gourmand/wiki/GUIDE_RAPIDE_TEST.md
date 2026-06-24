# 🚀 GUIDE RAPIDE - TESTER L'APPLICATION

## ✅ **L'APPLICATION EST PRÊTE !**

### 🎯 **Démarrage**
1. L'application démarre automatiquement avec **Marie Dubois** (cliente)
2. Un message de bienvenue s'affiche (1 seule fois)
3. Le **bouton flottant** est visible en bas à droite

### 🔄 **Changer d'Utilisateur - EN 1 CLIC !**

#### **Étape 1** : Cliquez sur le bouton flottant
```
┌─────────────────────────────┐
│ 🛒 Client                   │
│ Marie Dubois             ▲  │
└─────────────────────────────┘
```

#### **Étape 2** : Panel s'ouvre avec 8 utilisateurs
```
┌─────────────────────────────┐
│ 👥 Changement Rapide        │
├─────────────────────────────┤
│ 👑 Admin                    │
│  Julie (Admin)              │
├─────────────────────────────┤
│ 👔 Employés                 │
│  Sophie (Employé)           │
│  Marc (Employé)             │
├─────────────────────────────┤
│ 🛒 Clients                  │
│  Marie (Client)          ✓  │
│  Jean (Client)              │
│  Claire (Client)            │
│  Thomas (Client)            │
│  Isabelle (Client)          │
└─────────────────────────────┘
```

#### **Étape 3** : Cliquez sur l'utilisateur souhaité
- ✅ Changement instantané
- ✅ Toast de confirmation
- ✅ Panel se ferme

---

## 🎭 **SCÉNARIOS DE TEST**

### **🛒 SCÉNARIO CLIENT** (Marie, Jean, Claire...)

#### **1. Commander un Menu**
1. Basculer vers un client (ex: **Marie Dubois**)
2. Cliquer sur **"Menus"** dans la navbar
3. Choisir un menu et cliquer **"Commander ce menu"**
4. **OrderPage moderne** s'ouvre avec :
   - Infos pré-remplies (nom, email, téléphone, adresse)
   - Date et heure du repas
   - Nombre de personnes
5. Valider la commande
6. ✅ Commande créée et visible dans le Kanban

#### **2. Voir l'Espace Utilisateur**
1. Cliquer sur **"Mon Espace"** dans la navbar
2. Voir :
   - Points de fidélité
   - Historique des commandes
   - Profil
   - Parrainage

#### **3. Tester Nouveau Client vs VIP**
- **Thomas Rousseau** : 1 commande, découverte
- **Isabelle Leroy** : 18 commandes, statut VIP

---

### **👔 SCÉNARIO EMPLOYÉ** (Sophie, Marc)

#### **1. Gérer le Kanban**
1. Basculer vers **Sophie Laurent**
2. Cliquer sur **"Dashboard"** dans la navbar
3. Aller sur l'onglet **"Commandes"**
4. Voir le Kanban avec 5 colonnes :
   - En attente
   - Confirmée
   - En préparation
   - Prête
   - Livrée

#### **2. Prendre en Charge une Commande**
1. Trouver une commande "En attente"
2. Cliquer **"Prendre en charge"**
3. La commande passe en "Confirmée"

#### **3. Déplacer une Commande**
1. Cliquer sur **"Suivant >"** pour avancer
2. Cliquer sur **"< Précédent"** pour reculer
3. ✅ La commande change de colonne instantanément

#### **4. Cocher les Plats Préparés**
1. Ouvrir le détail d'une commande
2. Cocher les plats au fur et à mesure
3. Suivre la progression en %

---

### **👑 SCÉNARIO ADMIN** (Julie)

#### **1. Accéder au Dashboard Complet**
1. Basculer vers **Julie Mercier**
2. Cliquer sur **"Dashboard"**
3. Voir tous les onglets :
   - Vue d'ensemble (Analytics)
   - Commandes (Kanban)
   - Utilisateurs
   - Menus
   - Avis
   - CMS

#### **2. Gérer les Utilisateurs**
1. Aller sur l'onglet **"Utilisateurs"**
2. Voir la table complète avec :
   - 10 utilisateurs
   - Filtres par rôle
   - Recherche
   - Pagination (50/page)
3. Cliquer sur un utilisateur pour voir détails

#### **3. Voir les Analytics**
1. Onglet **"Vue d'ensemble"**
2. Voir graphiques :
   - Chiffre d'affaires
   - Commandes par statut
   - Top clients
   - Performance

---

## 🎯 **FLOW COMPLET DE BOUT EN BOUT**

### **Test : Commande Client → Gestion Employé → Validation Admin**

#### **1. COMMANDER (en tant que Client)**
1. Basculer vers **Jean Martin**
2. Menu → Choisir "Menu Prestige"
3. Commander pour 10 personnes, samedi prochain
4. ✅ Commande créée

#### **2. GÉRER (en tant qu'Employé)**
1. Basculer vers **Sophie Laurent**
2. Dashboard → Commandes
3. Voir la nouvelle commande de Jean en "En attente"
4. "Prendre en charge" → Passe en "Confirmée"
5. "Suivant >" → Passe en "En préparation"
6. Cocher les plats préparés
7. "Suivant >" → Passe en "Prête"
8. "Suivant >" → Passe en "Livrée"
9. ✅ Commande terminée

#### **3. ANALYSER (en tant qu'Admin)**
1. Basculer vers **Julie Mercier**
2. Dashboard → Vue d'ensemble
3. Voir les statistiques mises à jour
4. Utilisateurs → Voir Jean Martin avec sa nouvelle commande
5. ✅ Tout est à jour

---

## 💡 **ASTUCES**

### **Raccourcis**
- **Un clic** sur le bouton flottant = Ouvrir/Fermer
- **Un clic** sur un utilisateur = Changer instantanément
- **Pas besoin de fermer** le panel après changement (auto-close)

### **Indicateurs Visuels**
- ✅ **Check vert** = Utilisateur actuel
- 🔴 **Rouge** = Admin
- 🔵 **Bleu** = Employés
- 🟢 **Vert** = Clients

### **Notifications**
- Toast en haut à droite confirme chaque changement
- Affiche nom + rôle de l'utilisateur

---

## 📊 **UTILISATEURS DISPONIBLES**

### **👑 Admin (1)**
- **Julie Mercier** - Fondatrice, accès complet

### **👔 Employés (2)**
- **Sophie Laurent** - Responsable cuisine
- **Marc Petit** - Responsable livraisons

### **🛒 Clients (5)**
- **Marie Dubois** - 12 cmd, 8450€ (Régulière)
- **Jean Martin** - 8 cmd, 15200€ (VIP)
- **Claire Bernard** - 5 cmd, 3200€ (Moyenne)
- **Thomas Rousseau** - 1 cmd, 450€ (Nouveau)
- **Isabelle Leroy** - 18 cmd, 23400€ (Top cliente)

---

## 🎉 **C'EST PARTI !**

### **Pour Commencer**
1. ✅ L'app est déjà démarrée avec Marie Dubois
2. ✅ Cliquez sur le bouton flottant
3. ✅ Explorez les 8 utilisateurs
4. ✅ Testez tous les scénarios

### **Pour Impressionner**
- Changez d'utilisateur en 1 seconde
- Montrez le flow complet client → employé → admin
- Démontrez les différences de permissions par rôle

---

## 🚀 **TOUT EST PRÊT !**

**Aucune configuration nécessaire.**
**Aucun login requis.**
**Juste cliquer et tester !**

**BON TEST ! 🎊**
