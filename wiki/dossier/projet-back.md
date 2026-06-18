# 📁 mini-baas-infra — Documentation d'Architecture Back-End

> Plateforme BaaS auto-hébergée, orientée Docker Compose, conçue comme une **usine à backends génériques** capable de fournir authentification, données relationnelles, données documentaires, requêtage multi-tenant, temps réel, stockage objet, email transactionnel et politiques de sécurité unifiées sans développement d'API métier spécifique pour chaque nouveau projet.

---

## 📋 Table des Matières

1. [Team information](#team-information)
1. [Liste des Compétences Couvertes](#1-liste-des-compétences-couvertes)
1. [Expression des Besoins](#2-expression-des-besoins)
   - 2.1 [Objectifs du Projet](#21-objectifs-du-projet)
   - 2.2 [Limites du Projet](#22-limites-du-projet)
   - 2.3 [Livrables Attendus](#23-livrables-attendus)
1. [Environnement Technique](#3-environnement-technique)
   - 3.1 [Technologies Front-End](#31-technologies-front-end)
   - 3.2 [Technologies Back-End](#32-technologies-back-end)
   - 3.3 [Outils & Environnement de Développement](#33-outils--environnement-de-développement)
1. [Réalisations Front-End](#4-réalisations-front-end)
   - 4.1 [Maquettes des Interfaces Utilisateur](#41-maquettes-des-interfaces-utilisateur)
   - 4.2 [Enchaînement des Maquettes](#42-enchaînement-des-maquettes)
   - 4.3 [Interfaces Statiques](#43-interfaces-statiques)
   - 4.4 [Partie Dynamique des Interfaces](#44-partie-dynamique-des-interfaces)
   - 4.5 [Adaptation Web & Web Mobile (Responsive)](#45-adaptation-web--web-mobile-responsive)
1. [Réalisations Back-End](#5-réalisations-back-end)
   - 5.1 [Architecture & Structure](#51-architecture--structure)
   - 5.2 [Base de Données](#52-base-de-données)
   - 5.3 [API / Routes](#53-api--routes)
1. [Sécurité](#6-sécurité)
   - 6.1 [Mesures de Sécurité Côté Front-End](#61-mesures-de-sécurité-côté-front-end)
   - 6.2 [Veille sur les Vulnérabilités](#62-veille-sur-les-vulnérabilités)
1. [Jeu d'Essai](#7-jeu-dessai)
1. [Installation & Utilisation](#8-installation--utilisation)
   - 8.1 [Prérequis](#81-prérequis)
   - 8.2 [Installation](#82-installation)
   - 8.3 [Lancement du Projet](#83-lancement-du-projet)

- 8.4 [Séquence de démarrage service par service](#84-séquence-de-démarrage-service-par-service)
- 8.5 [Cycle complet des requêtes principales](#85-cycle-complet-des-requêtes-principales)

1. [Risques, Limites & Améliorations Futures](#9-risques-limites--améliorations-futures)
1. [Glossaire](#10-glossaire)
1. [Structure du Projet](#11-structure-du-projet)
1. [Cartographie des Fichiers Sources](#12-cartographie-des-fichiers-sources)
1. [Annexes](#13-annexes)

---

# Team information

## Composition observée du projet

À l'état actuel du dépôt, le projet semble être porté principalement par **dlesieur**. Cette documentation est rédigée de manière à pouvoir être utilisée dans un cadre pédagogique individuel **ou** collectif.

### Répartition des rôles proposée

| Membre   | Rôle principal                                     | Responsabilités observées / déduites                                                                                                                                    |
| -------- | -------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| dlesieur | Product Owner / Tech Lead / DevOps / Back-End Lead | Conception de l'architecture, intégration Docker, orchestration des services, sécurité, écriture des services NestJS, outillage d'exploitation, documentation technique |

> Si le projet est présenté en groupe, ce tableau peut être enrichi avec les noms réels de l'équipe. La structure documentaire ci-dessous reste valable.

## Organisation projet

### Méthodologie de travail

Le dépôt montre une approche **incrémentale et modulaire** :

- construction par services indépendants ;
- montée progressive en complexité ;
- documentation parallèle à l'implémentation ;
- validation régulière par scripts de tests par phases ;
- séparation claire entre infrastructure, services applicatifs, scripts, documentation et configuration.

Cette stratégie est cohérente avec une démarche de type :

- **itérative** pour l'ajout des fonctionnalités ;
- **DevOps** pour l'automatisation du build, du run et des vérifications ;
- **contract-first** pour plusieurs composants exposés via routes et DTOs ;
- **security-first** pour l'authentification, l'isolation et le chiffrement.

### Outils de gestion et communication

Même si tous les outils externes ne sont pas visibles dans le dépôt, la structure laisse apparaître une pratique compatible avec :

- Git / GitHub pour le versionnement ;
- Issues / milestones / branches pour la traçabilité ;
- documentation Markdown comme base de communication technique ;
- scripts shell et Makefile comme standard d'exécution pour l'équipe ;
- Docker Compose comme contrat de déploiement partagé.

## Stack technique globale

| Domaine              | Choix                                  | Justification                                                                        |
| -------------------- | -------------------------------------- | ------------------------------------------------------------------------------------ |
| Orchestration locale | Docker Compose                         | Reproductibilité, isolement, simplicité de démarrage                                 |
| Gateway              | Kong                                   | Centralisation des plugins, auth, rate-limit, CORS, routage                          |
| Auth                 | GoTrue                                 | Gestion prête à l'emploi des comptes, JWT, MFA, rotation de refresh token            |
| SQL REST             | PostgREST                              | Exposition automatique d'une API relationnelle sans écrire de contrôleurs métier     |
| DB relationnelle     | PostgreSQL 16                          | RLS, robustesse, SQL mature, extensibilité                                           |
| DB documentaire      | MongoDB 7                              | Modèle souple, change streams, adaptation aux données non strictement relationnelles |
| Microservices custom | NestJS 10 + TypeScript 5               | Modularité, DI, DTO, maintenabilité                                                  |
| Temps réel           | realtime-agnostic                      | Diffusion temps réel des mutations PostgreSQL et MongoDB                             |
| Stockage objet       | MinIO + AWS SDK S3                     | Compatibilité S3 et simplicité d'auto-hébergement                                    |
| Email                | Nodemailer + SMTP                      | Standard simple, interopérable, découplé du fournisseur                              |
| Observabilité        | Prometheus + Grafana + Loki + Promtail | Mesures, dashboards et logs centralisés                                              |
| Sécurité des secrets | Vault + chiffrement AES-256-GCM        | Réduction de l'exposition des secrets et chiffrement des credentials sensibles       |

## Base de données : logique d'ensemble

Le projet ne repose pas sur **une seule** base de données, mais sur plusieurs couches :

1. **PostgreSQL système** : stocke utilisateurs, rôles, policies, registres, tables métiers SQL.
2. **MongoDB système** : stocke documents orientés collections avec isolation par `owner_id`.
3. **Bases externes enregistrées** : PostgreSQL ou MongoDB tiers, branchés dynamiquement via l'`adapter-registry`.
4. **Registres internes** : `tenant_databases`, `schema_registry`, `roles`, `user_roles`, `resource_policies`.

## Liste de fonctionnalités implémentées

### Fonctionnalités cœur

| Fonctionnalité        | Description                                                         |
| --------------------- | ------------------------------------------------------------------- |
| Authentification      | Inscription, connexion, JWT, MFA, refresh token rotation            |
| Gateway centralisée   | Routage unique, plugins de sécurité, normalisation des échanges     |
| API SQL générique     | REST automatique sur PostgreSQL via PostgREST                       |
| API Mongo générique   | CRUD propriétaire sur collections MongoDB                           |
| Requêtage universel   | `query-router` vers PostgreSQL ou MongoDB externes                  |
| Registre de bases     | Ajout dynamique de bases distantes, credentials chiffrés            |
| Génération de schémas | Création de tables/collections à partir d'une spécification unifiée |
| Contrôle d'accès      | RBAC + ABAC via rôles, policies, fonction `has_permission()`        |
| Stockage fichiers     | Génération d'URLs présignées S3 compatibles MinIO                   |
| Email transactionnel  | Envoi SMTP via service dédié                                        |
| Temps réel            | Diffusion des changements de données                                |
| Observabilité         | Logs, métriques, dashboards                                         |
| Validation et scripts | Contrôles shell, compose, secrets, smoke tests                      |

## Modules pédagogiques — proposition de catégorisation

> Cette sous-partie peut être utilisée dans un cadre d'exercice. La pondération ci-dessous est une **proposition de lecture pédagogique** de la complexité du système.

### Modules majeurs (2 pts)

| Module                       | Type   | Pourquoi majeur                                           |
| ---------------------------- | ------ | --------------------------------------------------------- |
| Kong Gateway                 | Majeur | Point d'entrée unique, sécurité transverse, routage       |
| Auth GoTrue + JWT            | Majeur | Identité, émission des tokens, MFA, sécurité utilisateur  |
| PostgreSQL + PostgREST + RLS | Majeur | Data plane relationnel auto-exposé                        |
| MongoDB + mongo-api          | Majeur | Data plane documentaire auto-exposé                       |
| adapter-registry             | Majeur | Fondement du backend générique multi-base                 |
| query-router                 | Majeur | Requêtage universel sans endpoint métier dédié            |
| schema-service               | Majeur | Génération de schémas et industrialisation des structures |
| permission-engine            | Majeur | Gouvernance des accès et ABAC                             |

### Modules mineurs (1 pt)

| Module                               | Type   | Pourquoi mineur                                     |
| ------------------------------------ | ------ | --------------------------------------------------- |
| storage-router                       | Mineur | Important mais périphérique au cœur data/auth       |
| email-service                        | Mineur | Service transverse simple mais utile                |
| Vault                                | Mineur | Sécurité d'environnement et gestion des secrets     |
| Observabilité                        | Mineur | Essentiel en production, indirect fonctionnellement |
| Trino / Studio / pg-meta / Supavisor | Mineur | Services d'admin, d'exploration ou d'optimisation   |
| Scripts d'automatisation             | Mineur | Support de qualité et d'opération                   |

---

## 1. Liste des Compétences Couvertes

Ce projet met en œuvre les compétences suivantes issues du référentiel, en les réinterprétant dans un contexte fortement orienté back-end, architecture et intégration.

**Activité Type 1 – Développer la partie front-end d'une application web ou web mobile sécurisée**

| #   | Compétence                                                                  | Mise en œuvre dans le projet                                                                                                                                                                                          |
| --- | --------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| C1  | Maquetter des interfaces utilisateur web ou web mobile                      | Le dépôt ne contient pas de front produit final, mais l'architecture est conçue pour supporter n'importe quel front via API unifiée ; les parcours d'usage sont documentables sous forme de flux d'écrans côté client |
| C2  | Réaliser des interfaces utilisateur statiques web ou web mobile             | Le dépôt contient un `playground` et des conventions d'intégration ; la partie interface finale est volontairement découplée du back-end                                                                              |
| C3  | Développer la partie dynamique des interfaces utilisateur web ou web mobile | Le système est pensé pour alimenter des interfaces dynamiques grâce à HTTP, JWT, WebSocket et API génériques                                                                                                          |

**Activité Type 2 – Développer la partie back-end d'une application web ou web mobile sécurisée**

| #   | Compétence                                    | Mise en œuvre dans le projet                                               |
| --- | --------------------------------------------- | -------------------------------------------------------------------------- |
| B1  | Concevoir une architecture applicative        | Microservices spécialisés, gateway unique, séparation des plans de données |
| B2  | Mettre en place une base de données           | PostgreSQL, MongoDB, rôles, policies, migrations, schémas dynamiques       |
| B3  | Développer des composants d'accès aux données | Engines SQL/Mongo, registre d'adaptateurs, query-router                    |
| B4  | Exposer des services réseau sécurisés         | Kong, JWT, key-auth, rate limiting, WAF                                    |
| B5  | Industrialiser et déployer                    | Docker Compose, bake, Makefile, scripts de validation                      |
| B6  | Garantir la sécurité                          | RLS, owner isolation, chiffrement AES-256-GCM, Vault, DTOs, guards         |

---

## 2. Expression des Besoins

### 2.1 Objectifs du Projet

Le projet répond à un besoin très clair : **disposer d'un backend réutilisable pour n'importe quel produit sans devoir recoder un serveur spécifique pour chaque nouveau cas d'usage**.

### Problème à résoudre

Dans de nombreux projets, une part importante du temps est consacrée à reconstruire les mêmes briques :

- authentification ;
- gestion des utilisateurs ;
- stockage relationnel ;
- stockage documentaire ;
- CRUD basiques ;
- contrôle des accès ;
- email ;
- upload de fichiers ;
- logs et observabilité ;
- exposition sécurisée des données.

L'objectif ici est de transformer ces briques répétitives en **moteurs génériques**.

### Objectif principal

Construire une plateforme BaaS auto-hébergée qui permette à un front-end, à un produit métier ou à un autre service de consommer des capacités back-end complètes **sans écrire d'API métier de base**.

### Objectifs secondaires

- unifier l'authentification derrière un seul point d'entrée ;
- prendre en charge PostgreSQL **et** MongoDB ;
- supporter des bases externes enregistrées dynamiquement ;
- industrialiser la création des schémas ;
- appliquer une sécurité native ;
- fournir une base exploitable localement, en démonstration ou en pré-production ;
- permettre l'observabilité et l'exploitation ;
- rendre le système extensible à d'autres moteurs et services.

### Public cible

| Cible                 | Usage                                                                          |
| --------------------- | ------------------------------------------------------------------------------ |
| Développeur front-end | Consommer auth, données, temps réel et fichiers sans créer son propre back-end |
| Équipe produit        | Démarrer rapidement un MVP avec des primitives déjà sécurisées                 |
| Intégrateur / DevOps  | Déployer une plateforme interne de services back-end mutualisés                |
| Équipe pédagogique    | Démontrer une architecture moderne, modulaire et sécurisée                     |

### 2.2 Limites du Projet

Le périmètre est volontairement concentré sur le back-end générique. Le projet **ne couvre pas** directement :

- une application front-end métier finalisée ;
- une logique business spécifique à un domaine fonctionnel précis ;
- une administration visuelle complète de tous les moteurs custom ;
- un cluster Kubernetes de production ;
- une gestion multi-région ;
- un workflow CI/CD complet dans ce dépôt même ;
- la compatibilité avec tous les moteurs SQL/NoSQL existants.

### Limites techniques actuelles à connaître

- le moteur principal custom générique cible surtout PostgreSQL et MongoDB ;
- les requêtes universelles restent volontairement encadrées pour garder un bon niveau de sécurité ;
- certaines extensions avancées (fédération, admin UI, objet storage) sont sous profils optionnels ;
- les fronts clients doivent respecter les contrats d'auth, d'API key et de JWT.

### 2.3 Livrables Attendus

- [x] Infrastructure Docker Compose fonctionnelle
- [x] Passerelle API centralisée
- [x] Authentification prête à l'emploi
- [x] Plan de données SQL générique
- [x] Plan de données MongoDB générique
- [x] Requêtage multi-tenant vers bases externes
- [x] Générateur de schémas SQL/Mongo
- [x] Moteur de permissions RBAC/ABAC
- [x] Documentation technique détaillée
- [x] Scripts de validation et de test
- [x] Support de démonstration technique

---

## 3. Environnement Technique

### 3.1 Technologies Front-End

Ce dépôt est **back-end first**. Il n'embarque pas une interface applicative finale complète, mais il est explicitement conçu pour être consommé par n'importe quel front-end.

| Technologie                    | Version               | Rôle                                                             |
| ------------------------------ | --------------------- | ---------------------------------------------------------------- |
| HTML5                          | -                     | Consommation possible par n'importe quel client Web              |
| CSS3                           | -                     | Hors du dépôt principal, utilisé par tout front connecté au BaaS |
| JavaScript / TypeScript        | Variable selon client | Intégration API, gestion JWT, appels temps réel                  |
| React / Vue / Angular / mobile | Non imposé            | L'architecture est volontairement agnostique côté client         |

### Pourquoi le front-end n'est pas couplé au dépôt

Le choix architectural fondamental du projet consiste à ne **pas** enfermer la solution dans un front unique. La plateforme doit pouvoir servir :

- une SPA Web ;
- une application mobile ;
- un back-office ;
- un chatbot ;
- un autre microservice.

Autrement dit, le front n'est pas absent par manque, mais parce que le projet vise un rôle d'**infrastructure de backend mutualisée**.

### 3.2 Technologies Back-End

| Technologie                 | Version                        | Rôle                                           |
| --------------------------- | ------------------------------ | ---------------------------------------------- |
| TypeScript                  | 5.7.3                          | Langage principal des microservices NestJS     |
| Node.js                     | 20 (Dockerfile)                | Runtime des services custom                    |
| NestJS                      | 10.x                           | Framework modulaire pour les services back-end |
| PostgreSQL                  | 16-alpine                      | Base relationnelle principale                  |
| MongoDB                     | 7                              | Base documentaire principale                   |
| Kong                        | 3.8                            | API Gateway et politique d'accès               |
| GoTrue                      | v2.188.1                       | Authentification, JWT, MFA                     |
| PostgREST                   | v12.2.3                        | API REST automatique sur PostgreSQL            |
| Redis                       | 7-alpine                       | Cache / support infra                          |
| MinIO                       | RELEASE.2025...                | Stockage objet compatible S3                   |
| Nodemailer                  | 6.9.x                          | Envoi d'email SMTP                             |
| Prometheus / Grafana / Loki | versions définies dans Compose | Observabilité                                  |

### Librairies significatives

| Librairie                     | Rôle                                     |
| ----------------------------- | ---------------------------------------- |
| `class-validator`             | Validation des DTO                       |
| `class-transformer`           | Transformation des requêtes entrantes    |
| `nestjs-pino`                 | Logs structurés                          |
| `@nestjs/axios`               | Appels HTTP inter-services               |
| `pg`                          | Connexion PostgreSQL custom              |
| `mongodb`                     | Client MongoDB custom                    |
| `@aws-sdk/client-s3`          | Interaction avec MinIO/S3                |
| `@willsoto/nestjs-prometheus` | Métriques Prometheus pour les services   |
| `uuid`                        | Génération d'identifiants et corrélation |

### 3.3 Outils & Environnement de Développement

| Outil                   | Usage                                                    |
| ----------------------- | -------------------------------------------------------- |
| VS Code                 | Édition et navigation de code                            |
| Git / GitHub            | Versionnement, historisation, collaboration              |
| Docker / Docker Compose | Exécution locale et orchestrée                           |
| Make                    | Commandes simplifiées d'exploitation                     |
| Bash                    | Scripts de validation, génération de secrets, migrations |
| Mermaid                 | Diagrammes d'architecture et de flux                     |
| Swagger / OpenAPI       | Documentation d'API des services NestJS                  |

### Architecture de build

Le dépôt contient un `src/Dockerfile` unifié permettant de builder les 7 applications NestJS via un argument `APP`.

Extrait significatif :

```dockerfile
ARG APP=adapter-registry

FROM node:${NODE_VERSION}-alpine AS deps
WORKDIR /app
COPY --link package.json package-lock.json ./
RUN npm ci

FROM deps AS build
ARG APP
COPY --link tsconfig.json tsconfig.build.json nest-cli.json ./
COPY --link libs/ ./libs/
COPY --link apps/ ./apps/
RUN npx nest build ${APP}
```

Ce choix évite de maintenir un Dockerfile par microservice, diminue la duplication et renforce la cohérence du monorepo.

---

## 4. Réalisations Front-End

> Cette section suit le plan demandé par l'exercice. Le dépôt étant centré sur le back-end, la partie front-end est décrite sous forme de **modèle d'intégration attendu** plutôt que comme un produit visuel final livré dans ce repository.

### 4.1 Maquettes des Interfaces Utilisateur

Le système est pensé pour alimenter plusieurs familles d'interfaces :

1. **application cliente métier** ;
2. **back-office d'administration** ;
3. **console de développement / playground** ;
4. **application mobile** ;
5. **microservice consommateur**.

### Maquette fonctionnelle type — application cliente

```mermaid
flowchart TD
    A[Accueil] --> B[Connexion / Inscription]
    B --> C[Dashboard]
    C --> D[Liste des ressources SQL]
    C --> E[Liste des documents MongoDB]
    C --> F[Fichiers / Upload]
    C --> G[Notifications temps réel]
    C --> H[Profil / rôles / sécurité]
```

### Maquette fonctionnelle type — console d'administration

```mermaid
flowchart TD
    A[Admin Home] --> B[Gestion des bases enregistrées]
    A --> C[Création de schémas]
    A --> D[Gestion des policies]
    A --> E[Logs & métriques]
    A --> F[Stockage objet]
```

### Choix ergonomiques recommandés

- séparation claire entre auth, données, stockage, administration ;
- affichage du contexte utilisateur courant (id, rôle, tenant) ;
- visibilité explicite des permissions ;
- retour d'erreur standardisé ;
- journalisation des requêtes critiques côté console.

### Emplacements recommandés pour captures d'écran

Dans une version rendue au jury, il est fortement recommandé d'insérer des captures ou mockups aux emplacements suivants :

1. **écran de connexion / inscription** ;
2. **tableau de bord principal** avec liens vers SQL, MongoDB, schémas, permissions ;
3. **écran d'enregistrement d'une base externe** ;
4. **écran de création d'un schéma** ;
5. **écran de requête universelle** ;
6. **écran d'observabilité** avec métriques ou logs ;
7. **écran de gestion des policies**.

#### Placeholder de figure — authentification

> **Figure 1 — Écran d'authentification**
> _Insérer ici une capture montrant les champs email, mot de passe, éventuellement MFA, ainsi que le parcours de récupération / inscription._

#### Placeholder de figure — dashboard

> **Figure 2 — Tableau de bord de la plateforme**
> _Insérer ici une capture de l'écran principal présentant les modules auth, SQL, Mongo, schemas, storage, permissions et monitoring._

#### Placeholder de figure — registre de bases

> **Figure 3 — Interface d'enregistrement d'une base externe**
> _Insérer ici une capture du formulaire permettant de choisir le moteur, le nom logique et la chaîne de connexion._

#### Placeholder de figure — observabilité

> **Figure 4 — Dashboard d'observabilité**
> _Insérer ici une capture Grafana ou Prometheus illustrant l'état du système et la supervision._

### 4.2 Enchaînement des Maquettes

Le back-end est construit pour supporter le cycle utilisateur suivant :

```mermaid
sequenceDiagram
    participant U as Utilisateur
    participant FE as Front-end
    participant K as Kong
    participant G as GoTrue
    participant S as Services

    U->>FE: Ouvre l'application
    FE->>K: POST /auth/v1/signup ou /token
    K->>G: Route auth
    G-->>FE: JWT + refresh token
    FE->>K: Appels API avec apikey + Bearer JWT
    K->>S: Routage + headers injectés
    S-->>FE: Données sécurisées
```

### 4.3 Interfaces Statiques

L'interface statique recommandée pour consommer le projet peut être structurée autour de blocs simples :

```html
<header class="topbar">
  <h1>Mini BaaS Console</h1>
  <div class="session">
    <span id="user-email"></span>
    <button id="logout">Se déconnecter</button>
  </div>
</header>

<main class="layout">
  <aside class="sidebar">
    <button data-view="sql">SQL</button>
    <button data-view="mongo">MongoDB</button>
    <button data-view="schemas">Schemas</button>
    <button data-view="policies">Policies</button>
    <button data-view="storage">Storage</button>
  </aside>

  <section class="content" id="app-view"></section>
</main>
```

Extrait CSS possible :

```css
.layout {
  display: grid;
  grid-template-columns: 280px 1fr;
  min-height: 100vh;
}

.sidebar {
  border-right: 1px solid #e5e7eb;
  padding: 1rem;
}

.content {
  padding: 1.5rem;
  background: #fafafa;
}
```

### 4.4 Partie Dynamique des Interfaces

Le front-end typique exploite principalement :

- les appels `fetch` / `axios` ;
- le stockage temporaire du JWT ;
- l'ajout des headers `apikey` et `Authorization` ;
- les WebSockets pour le temps réel ;
- l'affichage des réponses paginées.

Exemple d'appel dynamique vers le `query-router` :

```javascript
async function queryExternalDatabase(dbId, table, token, apikey, payload) {
  const res = await fetch(`/query/v1/query/${dbId}/tables/${table}`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${token}`,
      apikey,
    },
    body: JSON.stringify(payload),
  });

  if (!res.ok) {
    throw new Error(`HTTP ${res.status}`);
  }

  return res.json();
}
```

### 4.5 Adaptation Web & Web Mobile (Responsive)

Le système est particulièrement compatible avec une approche responsive car la logique métier est portée côté API et non côté rendu. Le front n'a donc qu'à gérer :

- la session ;
- les formulaires ;
- l'affichage des données ;
- l'état de chargement ;
- les erreurs.

Exemple de règles responsive :

```css
@media (max-width: 768px) {
  .layout {
    grid-template-columns: 1fr;
  }

  .sidebar {
    border-right: 0;
    border-bottom: 1px solid #e5e7eb;
  }
}
```

---

## 5. Réalisations Back-End

### 5.1 Architecture & Structure

Le projet suit une architecture **microservices intégrés par gateway**, avec une forte orientation **backend factory**.

### Idée directrice

Le système n'est pas un back-end d'application unique, mais un **socle** capable d'alimenter plusieurs projets différents grâce à des primitives génériques.

### Principe architectural central

Au lieu de créer pour chaque projet :

- un service auth ;
- un service users ;
- un CRUD SQL ;
- un CRUD NoSQL ;
- un moteur d'upload ;
- un système de policies ;
- un service email ;

...le dépôt construit une **plateforme partagée** déjà prête.

### Diagramme d'architecture global

```mermaid
graph TB
    subgraph Client[Clients]
        WEB[Web App]
        MOB[Mobile App]
        BO[Back Office]
        MS[Other Services]
    end

    subgraph Entry[Entrée unique]
        WAF[WAF / ModSecurity]
        KONG[Kong Gateway]
    end

    subgraph Identity[Identité]
        GOTRUE[GoTrue]
    end

    subgraph GenericData[Plans de données génériques]
        POSTGREST[PostgREST]
        MONGOAPI[mongo-api]
        QUERY[query-router]
        SCHEMA[schema-service]
        REGISTRY[adapter-registry]
        PERM[permission-engine]
        STORAGE[storage-router]
        EMAIL[email-service]
        REALTIME[realtime-agnostic]
    end

    subgraph Persistence[Persistance]
        PG[(PostgreSQL)]
        MG[(MongoDB)]
        S3[(MinIO / S3)]
        RD[(Redis)]
        EXT1[(External PostgreSQL)]
        EXT2[(External MongoDB)]
    end

    WEB --> WAF --> KONG
    MOB --> WAF
    BO --> WAF
    MS --> KONG

    KONG --> GOTRUE
    KONG --> POSTGREST
    KONG --> MONGOAPI
    KONG --> QUERY
    KONG --> SCHEMA
    KONG --> REGISTRY
    KONG --> PERM
    KONG --> STORAGE
    KONG --> EMAIL
    KONG --> REALTIME

    GOTRUE --> PG
    POSTGREST --> PG
    PERM --> PG
    REGISTRY --> PG
    SCHEMA --> PG
    MONGOAPI --> MG
    STORAGE --> S3
    REALTIME --> PG
    REALTIME --> MG
    QUERY --> EXT1
    QUERY --> EXT2
    SCHEMA --> EXT1
    SCHEMA --> EXT2
    RD --- KONG
```

### Rôle des grandes couches

| Couche              | Rôle                                                |
| ------------------- | --------------------------------------------------- |
| Ingress             | WAF + Kong                                          |
| Identity            | GoTrue                                              |
| Data plane SQL      | PostgREST + PostgreSQL                              |
| Data plane document | mongo-api + MongoDB                                 |
| Data plane externe  | adapter-registry + query-router + schema-service    |
| Policy plane        | permission-engine                                   |
| Side services       | storage-router, email-service, realtime             |
| Ops plane           | Prometheus, Grafana, Loki, Vault, Makefile, scripts |

### Monorepo NestJS

Le monorepo `src/` contient :

- **7 applications** ;
- **3 bibliothèques partagées**.

#### Applications

| Application         | Rôle                                                           |
| ------------------- | -------------------------------------------------------------- |
| `adapter-registry`  | stocker les connexions de bases externes chiffrées             |
| `query-router`      | exécuter des opérations génériques sur bases enregistrées      |
| `schema-service`    | créer / supprimer tables ou collections sur bases enregistrées |
| `permission-engine` | gérer rôles et policies ABAC/RBAC                              |
| `mongo-api`         | CRUD générique MongoDB local                                   |
| `storage-router`    | générer des URLs présignées                                    |
| `email-service`     | envoyer des emails SMTP                                        |

#### Bibliothèques

| Bibliothèque    | Rôle                                           |
| --------------- | ---------------------------------------------- |
| `libs/common`   | guards, decorators, filters, pipes, interfaces |
| `libs/database` | services PostgreSQL et MongoDB partagés        |
| `libs/health`   | endpoints live/ready standardisés              |

### Flux d'une requête typique

```mermaid
sequenceDiagram
    participant C as Client
    participant W as WAF
    participant K as Kong
    participant A as Auth / JWT plugin
    participant S as Service cible
    participant D as DB / Engine

    C->>W: Requête HTTP
    W->>K: Requête filtrée
    K->>A: key-auth + jwt + plugins
    A->>K: validation OK
    K->>S: headers injectés (X-User-Id, X-User-Role...)
    S->>D: opération métier ou générique
    D-->>S: résultat
    S-->>K: réponse JSON standardisée
    K-->>C: réponse enrichie headers sécurité
```

### Pourquoi cette architecture est générique

Le caractère générique vient de plusieurs choix structurants :

1. **les routes ne codent pas un domaine métier précis** ;
2. **les schémas peuvent être créés dynamiquement** ;
3. **les bases externes sont enregistrables à chaud** ;
4. **les contrôles d'accès sont pilotés par données** ;
5. **le front consomme uniquement des primitives standards** ;
6. **les services sont substituables et découplés**.

Autrement dit, le dépôt agit comme un **back-end programmable par configuration, schéma et policies**, et non comme un code d'application ad hoc.

### Lecture académique de l'architecture

Dans une lecture plus universitaire, cette plateforme peut être comprise comme la combinaison de quatre plans complémentaires :

1. **plan d'identité** : authentifie les utilisateurs et produit les preuves d'identité ;
2. **plan de contrôle** : décide qui peut faire quoi ;
3. **plan de données** : exécute effectivement les opérations sur les bases ;
4. **plan d'exploitation** : observe, déploie, valide et maintient la plateforme.

Cette séparation est importante car elle évite de confondre :

- la preuve d'identité,
- la décision d'autorisation,
- la manipulation de données,
- et la gouvernance opérationnelle.

Du point de vue de l'ingénierie logicielle, cette approche améliore :

- la **maintenabilité**, car chaque service a une responsabilité claire ;
- la **scalabilité organisationnelle**, car plusieurs équipes peuvent intervenir par domaine ;
- la **réutilisabilité**, car les primitives restent indépendantes d'un métier ;
- la **testabilité**, car chaque couche peut être validée séparément.

### Détail service par service

#### 1. Kong Gateway

Kong est le **point d'entrée unique**.

Fonctions assurées :

- routage ;
- plugin `key-auth` ;
- plugin `jwt` ;
- `cors` ;
- `correlation-id` ;
- `response-transformer` pour les headers de sécurité ;
- `rate-limiting` ;
- `request-size-limiting` ;
- `ip-restriction` sur certaines routes d'administration ;
- plugin `pre-function` pour propager les claims JWT aux services en headers de confiance.

Extrait important du comportement : le JWT est vérifié par Kong, puis ses claims sont projetés en :

- `X-User-Id`
- `X-User-Email`
- `X-User-Role`
- `X-Request-ID`

Les services NestJS n'ont donc pas besoin de revalider eux-mêmes le JWT pour le parcours standard via gateway.

#### 2. GoTrue

GoTrue fournit :

- signup ;
- login ;
- JWT ;
- MFA/TOTP ;
- refresh token rotation ;
- OAuth externes configurables ;
- email auth.

Il constitue la **source d'identité** du système.

#### 3. PostgreSQL + PostgREST

Ce binôme expose automatiquement une API relationnelle. Le choix est très fort : plutôt que coder des contrôleurs CRUD spécifiques, on laisse PostgREST générer l'API à partir des tables et des droits SQL.

La sécurité est garantie par les politiques RLS.

#### 4. MongoDB + mongo-api

MongoDB n'a pas un équivalent natif de PostgREST. Le projet fournit donc un service custom `mongo-api` qui implémente un CRUD générique owner-scoped.

Caractéristiques :

- `owner_id` injecté automatiquement ;
- filtres nettoyés ;
- `_id` validé ;
- pagination ;
- tri ;
- métriques Prometheus ;
- opérations d'admin séparées.

#### 5. adapter-registry

Service central pour la **connexion dynamique à des bases externes**.

Fonctions :

- enregistrer une base PostgreSQL ou MongoDB ;
- chiffrer sa chaîne de connexion ;
- appliquer une isolation multi-tenant via RLS sur `tenant_databases` ;
- permettre aux services internes autorisés de récupérer le secret déchiffré.

Sans lui, il n'y a pas de backend factory multi-projet.

#### 6. query-router

Le `query-router` est le moteur universel d'accès aux bases enregistrées.

Il :

- demande la connexion au registre ;
- détecte le moteur ;
- délègue vers l'engine PostgreSQL ou MongoDB ;
- impose l'isolation utilisateur ;
- applique les limites de requête.

Il permet donc d'interroger **n'importe quelle base enregistrée** sans écrire d'endpoint sur mesure.

#### 7. schema-service

Le `schema-service` industrialise la création des structures.

Il prend une spécification unifiée (`name`, `engine`, `database_id`, `columns`, etc.), puis :

- crée une table PostgreSQL avec colonnes standardisées et RLS ;
- ou crée une collection MongoDB avec validateur JSON Schema ;
- enregistre le résultat dans `schema_registry`.

Ce service est ce qui rapproche le plus le projet d'un **backend factory** au sens fort : on ne crée plus les structures à la main dans chaque projet.

#### 8. permission-engine

Le moteur de permissions gère :

- les rôles ;
- les rôles utilisateur ;
- les policies ressource/action ;
- la fonction SQL `has_permission()`.

Il complète le RLS :

- le RLS protège les lignes ;
- le permission-engine gouverne les accès applicatifs plus généraux.

#### 9. storage-router

Ce service génère des URLs S3 présignées. Il évite d'exposer des credentials de stockage au client.

Il applique aussi une isolation simple par préfixage du chemin avec l'identifiant utilisateur.

#### 10. email-service

Service dédié à l'envoi d'emails SMTP : découplage du transport, maintien d'une responsabilité claire et mutualisation entre projets.

#### 11. realtime

Service de diffusion des changements temps réel. Il complète les opérations CRUD en permettant à un front de réagir aux mutations de données sans polling permanent.

### Sous-sections dédiées aux applications NestJS

Les paragraphes précédents donnent une vue synthétique. Pour une lecture de soutenance, il est utile d'aller plus loin application par application.

#### `adapter-registry` — registre sécurisé d'adaptateurs

**Responsabilité principale :** faire le lien entre un utilisateur / tenant et une base de données externe enregistrée dynamiquement.

**Capacités fonctionnelles :**

- enregistrer un moteur (`postgresql`, `mongodb`, etc.) ;
- stocker le nom logique d'une base ;
- chiffrer la chaîne de connexion ;
- lister les bases visibles par le tenant courant ;
- fournir le secret déchiffré aux services internes autorisés ;
- supprimer une entrée de registre.

**Choix techniques notables :**

- chiffrement AES-256-GCM ;
- table `tenant_databases` protégée par RLS ;
- `ServiceTokenGuard` pour l'accès interne au endpoint de connexion ;
- exposition Swagger ;
- usage de `PostgresService` partagé.

**Intérêt dans l'architecture :** c'est la brique qui rend la plateforme multi-projet et multi-base. Sans elle, le système resterait limité aux bases internes.

#### `query-router` — moteur universel de requêtes

**Responsabilité principale :** offrir un point d'accès unique pour exécuter des opérations génériques sur une base enregistrée.

**Capacités fonctionnelles :**

- résolution de la connexion réelle ;
- dispatch moteur SQL / Mongo ;
- opérations CRUD normalisées ;
- limitation des résultats ;
- support du filtrage et du tri ;
- propagation du contexte utilisateur pour l'isolation.

**Choix techniques notables :**

- moteur PostgreSQL avec validation des noms de table / colonne ;
- moteur MongoDB avec nettoyage des filtres ;
- injection automatique de `owner_id` sur insertion ;
- propagation de `app.current_user_id` pour les tables externes RLS.

**Intérêt dans l'architecture :** il supprime la nécessité d'écrire un service d'accès aux données pour chaque base externe et chaque projet.

#### `schema-service` — industrialisation des structures

**Responsabilité principale :** transformer une spécification de schéma unifiée en structure physique réelle sur un moteur PostgreSQL ou MongoDB.

**Capacités fonctionnelles :**

- création de table PostgreSQL ;
- activation RLS sur base externe ;
- création de collection MongoDB ;
- pose d'un validateur JSON Schema ;
- suppression de structures ;
- enregistrement du schéma produit dans `schema_registry`.

**Choix techniques notables :**

- ajout systématique de colonnes techniques ;
- garde-fou sur les types SQL supportés ;
- création d'une fonction `current_user_id()` pour les bases externes PostgreSQL ;
- persistance d'un registre central de schémas créés.

**Intérêt dans l'architecture :** il transforme le dépôt en fabrique de structures de données, et pas seulement en passerelle HTTP.

#### `permission-engine` — gouvernance et ABAC

**Responsabilité principale :** exprimer les droits sous forme de rôles et de policies de manière centralisée.

**Capacités fonctionnelles :**

- affectation de rôles ;
- révocation ;
- consultation des rôles d'un utilisateur ;
- création / suppression de policies ;
- évaluation d'un accès via `has_permission()`.

**Choix techniques notables :**

- stockage SQL des rôles et policies ;
- hiérarchie par priorité ;
- logique deny-first à priorité égale ;
- articulation avec `RolesGuard` côté API.

**Intérêt dans l'architecture :** il évite que les règles d'autorisation soient dispersées dans chaque microservice ou application cliente.

#### `mongo-api` — data plane documentaire générique

**Responsabilité principale :** exposer un CRUD propre sur MongoDB local sans code métier spécifique.

**Capacités fonctionnelles :**

- création de documents ;
- lecture paginée et filtrée ;
- lecture par identifiant ;
- mise à jour partielle ;
- suppression ;
- endpoints d'administration de schémas / index.

**Choix techniques notables :**

- injection de `owner_id` ;
- suppression des champs interdits ;
- validation des ObjectId ;
- instrumentation Prometheus ;
- séparation entre `collections` et `admin`.

**Intérêt dans l'architecture :** il fournit à MongoDB ce que PostgREST fournit à PostgreSQL : une couche API générique stable.

#### `storage-router` — façade d'accès au stockage objet

**Responsabilité principale :** sécuriser l'accès au stockage par génération d'URLs temporaires.

**Capacités fonctionnelles :**

- signature GET ;
- signature PUT ;
- délai d'expiration contrôlé ;
- préfixage automatique du chemin avec l'utilisateur.

**Intérêt dans l'architecture :** il retire au front la responsabilité de manipuler des secrets d'accès S3.

#### `email-service` — service transverse d'envoi

**Responsabilité principale :** centraliser les envois SMTP et découpler les applications métiers du transport email.

**Capacités fonctionnelles :**

- envoi HTML ou texte ;
- configuration SMTP externe ;
- vérification de connectivité ;
- journalisation structurée.

**Intérêt dans l'architecture :** mutualiser l'email évite de recoder la même logique dans chaque projet consommateur.

### Sous-sections dédiées aux bibliothèques partagées

#### `libs/common`

Cette bibliothèque mutualise le vocabulaire de sécurité et de transport : `AuthGuard`, `RolesGuard`, `ServiceTokenGuard`, décorateur `CurrentUser`, filtre d'exceptions, pipe de validation, intercepteur de corrélation.

**Apport architectural :** elle évite la divergence de comportement entre services.

#### `libs/database`

Cette bibliothèque fournit les services `PostgresService` et `MongoService`.

**Apport architectural :** centralisation des pools, de la santé des connexions, et des patterns d'accès.

#### `libs/health`

Cette bibliothèque standardise les endpoints `live` et `ready`.

**Apport architectural :** facilite l'orchestration Compose, les healthchecks et l'observabilité.

### Sous-sections dédiées aux services Docker d'infrastructure

Au-delà des applications NestJS, l'architecture repose sur plusieurs conteneurs d'infrastructure qui méritent eux aussi une lecture détaillée.

#### `waf`

Ce conteneur joue le rôle de bouclier HTTP initial. Il complète Kong par une logique de défense plus orientée filtrage de patterns suspects.

#### `kong`

Kong est le centre nerveux du trafic HTTP. Son fichier déclaratif définit :

- les routes ;
- les services upstream ;
- les plugins globaux ;
- les règles spécifiques à certains endpoints.

#### `postgres`

Base relationnelle principale du système. Elle porte à la fois les données de démonstration et les métadonnées critiques d'architecture.

#### `db-bootstrap`

Job one-shot de préparation :

- rôles SQL ;
- schéma auth ;
- tables de démonstration ;
- policies RLS ;
- tables de registre ;
- permissions de base.

Son existence renforce le caractère reproductible de la plateforme.

#### `mongo` + `mongo-init`

MongoDB est démarré avec un replica set afin de supporter les change streams. `mongo-init` finalise l'initialisation.

#### `gotrue`

Fournisseur d'identité du système. Il remplace le besoin d'un développement sur mesure pour toute la partie comptes, login et MFA.

#### `postgrest`

Expose la donnée relationnelle directement depuis PostgreSQL. C'est un accélérateur considérable pour construire un backend sans re-développer les opérations basiques.

#### `realtime`

Diffuse les changements de données. C'est la brique qui rapproche la plateforme d'une expérience moderne orientée événements.

#### `redis`

Service d'appui pour la pile, utile pour certains patterns de cache ou composants temps réel selon les scénarios d'usage.

#### `minio`

Fournit un stockage objet auto-hébergé compatible S3, activable en profil `extras`.

#### `vault` + `vault-init`

Participent à la stratégie globale de gestion des secrets. Même si le projet utilise aussi un `.env` pour le local, l'architecture montre une orientation vers une gestion plus mature des secrets.

#### `prometheus`, `grafana`, `loki`, `promtail`

Ils constituent le plan observabilité :

- métriques ;
- tableaux de bord ;
- centralisation des logs.

#### `studio`, `pg-meta`, `supavisor`, `trino`

Services complémentaires d'administration, de pooling et d'exploration. Ils ne sont pas obligatoires au cœur du backend, mais renforcent l'écosystème de la plateforme.

### Analyse comparative avec un backend sur mesure classique

Pour mieux comprendre l'originalité du projet, il est utile de le comparer à une architecture plus classique dans laquelle une équipe construit manuellement son API métier.

| Critère                    | Backend classique spécifique             | mini-baas-infra                      |
| -------------------------- | ---------------------------------------- | ------------------------------------ |
| Authentification           | Souvent développée ou intégrée à la main | Mutualisée via GoTrue                |
| CRUD SQL                   | Contrôleurs et services spécifiques      | Automatique via PostgREST            |
| CRUD Mongo                 | Souvent ad hoc par collection            | Générique via `mongo-api`            |
| Gestion des bases externes | Rare, coûteuse, spécifique               | Native via `adapter-registry`        |
| Création de schémas        | Scripts ou migrations dédiés par projet  | Générique via `schema-service`       |
| Permissions                | Souvent dispersées dans le code          | Centralisées via `permission-engine` |
| Stockage                   | Intégration par projet                   | Mutualisé via `storage-router`       |
| Email                      | Implémentation spécifique                | Mutualisé via `email-service`        |
| Réutilisabilité            | Faible à moyenne                         | Élevée                               |
| Time-to-market             | Plus long                                | Réduit                               |

Cette comparaison montre que le projet ne se contente pas d'être une stack technique : il réduit explicitement la redondance structurelle entre projets.

### Exemple de garde d'authentification partagée

```typescript
canActivate(context: ExecutionContext): boolean {
  const req = context.switchToHttp().getRequest<Request>();
  const userId = req.headers['x-user-id'] as string | undefined;

  if (!userId) {
    throw new UnauthorizedException('Missing authenticated user headers');
  }

  req.user = {
    id: userId,
    email: (req.headers['x-user-email'] as string | undefined) ?? '',
    role: (req.headers['x-user-role'] as string | undefined) ?? 'authenticated',
  };

  return true;
}
```

Ce code montre bien la philosophie du projet : le service fait confiance au gateway, ce qui simplifie fortement les microservices.

### Exemple de récupération d'une base enregistrée

```typescript
private async fetchConnection(dbId: string, userId: string): Promise<AdapterResponse> {
  const url = `${this.registryUrl}/databases/${dbId}/connect`;
  const { data } = await firstValueFrom(
    this.http.get<AdapterResponse>(url, {
      headers: {
        'X-Service-Token': this.serviceToken,
        'X-Tenant-Id': userId,
      },
    }),
  );
  return data;
}
```

Le `query-router` n'embarque aucun secret en dur pour les bases externes : il passe toujours par le registre.

### Exemple de logique de chiffrement

Le registre chiffre les chaînes de connexion avec AES-256-GCM et dérivation `scrypt`.

Pourquoi ce choix ?

- confidentialité au repos ;
- authenticité de la donnée via tag GCM ;
- robustesse cryptographique ;
- adaptation naturelle à un stockage binaire en base.

---

### 5.2 Base de Données

La stratégie base de données est **polyglotte**.

```mermaid
flowchart LR
    subgraph Internal
        PGSYS[(PostgreSQL système)]
        MGSYS[(MongoDB système)]
    end

    subgraph External
        PGTEN[(PostgreSQL externes)]
        MGTEN[(MongoDB externes)]
    end

    REG[adapter-registry] --> PGSYS
    PERM[permission-engine] --> PGSYS
    POST[PostgREST] --> PGSYS
    MAPI[mongo-api] --> MGSYS
    QUERY[query-router] --> PGTEN
    QUERY --> MGTEN
    SCHEMA[schema-service] --> PGTEN
    SCHEMA --> MGTEN
```

### Modèle relationnel principal

Le PostgreSQL système contient plusieurs familles de tables.

#### Tables métier / démonstration

- `users`
- `user_profiles`
- `posts`
- `projects`
- `mock_orders`

#### Tables d'infrastructure

- `tenant_databases`
- `schema_registry`
- `roles`
- `user_roles`
- `resource_policies`
- `schema_migrations`

### Schéma logique simplifié

```mermaid
erDiagram
    USERS ||--o{ USER_PROFILES : owns
    USERS ||--o{ POSTS : writes
    USERS ||--o{ USER_ROLES : receives
    ROLES ||--o{ USER_ROLES : grants
    ROLES ||--o{ RESOURCE_POLICIES : defines
    TENANT_DATABASES ||--o{ SCHEMA_REGISTRY : contains

    USERS {
        uuid id PK
        text email
        text name
        timestamptz created_at
    }

    USER_PROFILES {
        uuid id PK
        uuid user_id FK
        text bio
        text avatar_url
    }

    POSTS {
        uuid id PK
        uuid user_id FK
        text title
        text content
        boolean is_public
    }

    ROLES {
        uuid id PK
        text name
        boolean is_system
        jsonb metadata
    }

    USER_ROLES {
        uuid id PK
        uuid user_id
        uuid role_id
        uuid granted_by
        timestamptz expires_at
    }

    RESOURCE_POLICIES {
        uuid id PK
        uuid role_id
        text resource_type
        text resource_name
        text[] actions
        jsonb conditions
        text effect
        int priority
    }

    TENANT_DATABASES {
        uuid id PK
        text tenant_id
        text engine
        text name
        bytea connection_enc
    }

    SCHEMA_REGISTRY {
        uuid id PK
        uuid database_id
        text name
        text engine
        jsonb columns
        boolean enable_rls
    }
```

### PostgreSQL : isolation par RLS

L'isolation est déléguée à la base elle-même.

Exemple simplifié :

```sql
CREATE POLICY projects_owner_crud ON public.projects
  FOR ALL USING (
    auth.uid()::text = owner_id
  )
  WITH CHECK (
    auth.uid()::text = owner_id
  );
```

Sur les bases externes créées par `schema-service`, la logique est adaptée pour utiliser le contexte injecté via `current_setting('app.current_user_id')`.

### Tables externes générées automatiquement

Quand `schema-service` crée une table PostgreSQL externe, il ajoute de façon standard :

- `id UUID PRIMARY KEY DEFAULT gen_random_uuid()`
- `owner_id UUID NOT NULL`
- `created_at TIMESTAMPTZ DEFAULT now()`
- `updated_at TIMESTAMPTZ DEFAULT now()`

Ce choix permet d'imposer un socle commun à tous les projets sans exiger que chaque développeur repense sa stratégie d'isolation.

### MongoDB : modèle documentaire et validateur

La logique MongoDB repose sur :

- un `owner_id` obligatoire ;
- des timestamps ;
- des validateurs JSON Schema ;
- un CRUD filtré côté API.

Schéma logique type :

```mermaid
flowchart TD
    DOC[Document métier] --> OWNER[owner_id]
    DOC --> DATA[champs métier]
    DOC --> CREATED[created_at]
    DOC --> UPDATED[updated_at]
```

### Pourquoi le choix polyglotte est pertinent

| Besoin                          | PostgreSQL                | MongoDB                  |
| ------------------------------- | ------------------------- | ------------------------ |
| Données relationnelles strictes | Excellent                 | Moyen                    |
| Schéma souple                   | Moyen                     | Excellent                |
| RLS natif                       | Excellent                 | Non natif                |
| APIs auto-générées              | Excellent avec PostgREST  | Nécessite service custom |
| Change streams / temps réel     | Oui via mécanismes dédiés | Excellent                |

Le projet ne force donc pas un modèle unique. Il choisit le bon moteur selon la nature des données.

### Registre des bases externes

Le backend generic factory prend tout son sens avec `tenant_databases`.

Processus :

```mermaid
sequenceDiagram
    participant U as Utilisateur
    participant AR as adapter-registry
    participant PG as PostgreSQL système
    participant QR as query-router
    participant EXT as Base externe

    U->>AR: Enregistre une base (engine + name + connection_string)
    AR->>AR: Chiffre la chaîne de connexion
    AR->>PG: Stocke dans tenant_databases
    U->>QR: Demande une requête générique
    QR->>AR: Récupère la connexion via token service interne
    AR-->>QR: Retourne engine + connection_string déchiffrée
    QR->>EXT: Exécute l'opération
    EXT-->>QR: Résultat
```

### 5.3 API / Routes

L'API du projet est volontairement structurée par domaines transverses plutôt que par logique métier spécifique.

#### Routes principales exposées via Kong

| Méthode               | Route externe                           | Service           | Description                                           | Auth requise                 |
| --------------------- | --------------------------------------- | ----------------- | ----------------------------------------------------- | ---------------------------- |
| POST                  | `/auth/v1/signup`                       | GoTrue            | inscription utilisateur                               | apikey                       |
| POST                  | `/auth/v1/token`                        | GoTrue            | connexion et JWT                                      | apikey                       |
| GET                   | `/rest/v1/...`                          | PostgREST         | accès REST aux tables PostgreSQL                      | apikey + JWT selon ressource |
| GET/POST/PATCH/DELETE | `/mongo/v1/collections/:name/documents` | mongo-api         | CRUD générique MongoDB                                | apikey + JWT                 |
| GET                   | `/mongo/v1/admin/collections`           | mongo-api         | liste des collections                                 | apikey + JWT                 |
| POST                  | `/query/v1/query/:dbId/tables/:table`   | query-router      | requête universelle base enregistrée                  | apikey + JWT                 |
| GET                   | `/query/v1/query/:dbId/tables`          | query-router      | liste des tables / collections d'une base enregistrée | apikey + JWT                 |
| POST                  | `/schemas/v1/schemas`                   | schema-service    | création table / collection                           | apikey + JWT                 |
| GET                   | `/schemas/v1/schemas`                   | schema-service    | liste des schémas enregistrés                         | apikey + JWT                 |
| DELETE                | `/schemas/v1/schemas/:id`               | schema-service    | suppression d'un schéma                               | apikey + JWT                 |
| POST                  | `/admin/v1/databases`                   | adapter-registry  | enregistrement d'une base externe                     | apikey + JWT                 |
| GET                   | `/admin/v1/databases`                   | adapter-registry  | liste des bases de l'utilisateur                      | apikey + JWT                 |
| POST                  | `/permissions/v1/permissions/check`     | permission-engine | vérification d'accès                                  | apikey + JWT                 |
| GET                   | `/permissions/v1/policies`              | permission-engine | lecture des policies                                  | apikey + JWT admin           |
| POST                  | `/storage/v1/sign/:bucket/*`            | storage-router    | URL présignée                                         | apikey + JWT                 |
| POST                  | `/email/v1/send`                        | email-service     | envoi d'email                                         | apikey + JWT                 |
| GET                   | `/realtime/v1/...`                      | realtime          | temps réel                                            | apikey + JWT                 |

### Exemples de payloads

#### Enregistrement d'une base externe

```json
{
  "engine": "postgresql",
  "name": "customer-crm",
  "connection_string": "postgres://user:pass@host:5432/crm"
}
```

#### Création d'un schéma PostgreSQL

```json
{
  "name": "contacts",
  "engine": "postgresql",
  "database_id": "550e8400-e29b-41d4-a716-446655440000",
  "enable_rls": true,
  "columns": [
    { "name": "first_name", "type": "text", "nullable": false },
    { "name": "last_name", "type": "text", "nullable": false },
    { "name": "email", "type": "text", "nullable": false, "unique": true }
  ]
}
```

#### Requête universelle MongoDB

```json
{
  "action": "find",
  "filter": { "status": "active" },
  "sort": { "created_at": "desc" },
  "limit": 20,
  "offset": 0
}
```

#### Requête universelle PostgreSQL

```json
{
  "action": "insert",
  "data": {
    "title": "First note",
    "content": "Generic backend factory demo"
  }
}
```

### Pourquoi ces routes sont puissantes

Parce qu'elles reposent sur des **moteurs** et non sur des cas métiers figés :

- le même endpoint sert à plusieurs tables ;
- le même service fonctionne pour plusieurs projets ;
- la logique de sécurité reste uniforme ;
- la maintenance se concentre sur les primitives, pas sur des doublons.

---

## 6. Sécurité

La sécurité n'est pas un ajout tardif dans ce dépôt : elle est un **axe d'architecture**.

### Vue d'ensemble des couches de sécurité

```mermaid
flowchart TD
    A[Client] --> B[WAF / ModSecurity]
    B --> C[Kong Gateway]
    C --> D[JWT + API Key + Plugins]
    D --> E[Services NestJS]
    E --> F[Validation DTO + Guards]
    F --> G[RLS PostgreSQL / owner isolation Mongo]
    G --> H[Chiffrement des secrets + Vault]
```

### 6.1 Mesures de Sécurité Côté Front-End

Même si le front n'est pas dans ce dépôt, les règles de sécurité côté client sont clairement induites par l'architecture.

| Vulnérabilité         | Mesure mise en place                                                       | Application au projet                                                     |
| --------------------- | -------------------------------------------------------------------------- | ------------------------------------------------------------------------- |
| XSS                   | Éviter `innerHTML`, utiliser échappement et rendu sûr                      | Tout client consommant les APIs doit afficher les données de manière sûre |
| CSRF                  | Usage de JWT Bearer et `apikey` plutôt que cookies de session implicites   | Les appels sont explicitement authentifiés                                |
| Vol de token          | Stockage prudent côté client, durée de vie limitée, refresh token rotation | Géré par GoTrue et le client                                              |
| Exposition de secrets | Aucun secret DB ni SMTP ni S3 côté front                                   | Toute opération sensible passe par les services                           |
| Accès latéral         | Headers et claims gérés par Kong, pas par le client directement            | Le front ne forge pas sa propre identité                                  |
| Upload dangereux      | URL présignée générée côté serveur                                         | Le client n'obtient pas les credentials S3                                |

### 6.2 Veille sur les Vulnérabilités

Sources de référence pertinentes pour ce projet :

- OWASP Top 10 ;
- documentations Kong, PostgreSQL, MongoDB, GoTrue ;
- guides de sécurité Docker ;
- avis CVE des images utilisées ;
- bonnes pratiques Node.js / NestJS.

### Vulnérabilités prises en compte

| Vulnérabilité                   | Risque                          | Réponse dans l'architecture                                    |
| ------------------------------- | ------------------------------- | -------------------------------------------------------------- |
| Bypass d'auth                   | Accès non autorisé aux services | Kong applique `key-auth` et `jwt`                              |
| Falsification des claims        | Usurpation d'identité           | Les headers utilisateur proviennent du gateway, pas du client  |
| Injection SQL                   | Altération de requêtes          | Validation des noms, usage de paramètres, opérations encadrées |
| Injection Mongo                 | Filtres dangereux               | Suppression de `$where`, nettoyage des clés sensibles          |
| Escalade latérale entre tenants | Fuite de données                | RLS SQL, `owner_id` Mongo, policies                            |
| Fuite des chaînes de connexion  | Compromission de bases externes | AES-256-GCM + stockage chiffré                                 |
| Bruteforce / abus d'API         | Déni de service                 | Rate-limits Kong                                               |
| Upload malveillant              | Contenus abusifs                | Présignature contrôlée et isolation par préfixe utilisateur    |
| Sur-exposition admin            | Accès back-office               | `ip-restriction`, rôles, clés de service                       |

### 6.3 Mesures de sécurité côté back-end

#### 1. WAF en frontal

Le service `waf` ajoute une première barrière contre certaines classes d'attaques HTTP connues.

#### 2. Gateway avec politiques globales

Kong applique :

- contrôle d'API key ;
- validation JWT ;
- en-têtes de sécurité ;
- corrélation de requêtes ;
- taille de payload ;
- rate limiting.

#### 3. Validation stricte des entrées

Les services NestJS utilisent `class-validator` et `class-transformer` via un pipe global.

#### 4. Guards et rôles

- `AuthGuard` ;
- `RolesGuard` ;
- `ServiceTokenGuard`.

#### 5. Isolation des données

- PostgreSQL : `ROW LEVEL SECURITY` ;
- MongoDB : filtrage systématique par `owner_id` dans les services custom ;
- bases externes : contexte `app.current_user_id` propagé pour les tables générées.

#### 6. Chiffrement des secrets sensibles

Les chaînes de connexion externes ne sont jamais stockées en clair.

#### 7. Secrets d'environnement

Le script `generate-env.sh` fabrique un `.env` avec secrets aléatoires pour le développement local.

Extrait représentatif :

```bash
JWT_SECRET="$(openssl rand -hex 32)"
VAULT_ENC_KEY="$(openssl rand -hex 16)"
MINIO_ROOT_PASSWORD="$(openssl rand -hex 16)"
```

#### 8. Vérification automatisée

Le script `validate-all.sh` exécute :

- vérification shell ;
- vérification JavaScript ;
- validation Docker Compose ;
- contrôle des secrets ;
- scan de secrets hardcodés.

### 6.4 Pourquoi cette sécurité est adaptée à un backend générique

Une architecture générique est plus exposée qu'un back-end métier fermé, car elle manipule des primitives réutilisables. Il faut donc sécuriser le **cadre** lui-même :

- normaliser les entrées ;
- centraliser l'auth ;
- cloisonner les tenants ;
- contrôler les tailles de requêtes ;
- protéger les secrets ;
- gouverner les accès par rôles et policies.

Le projet y répond de façon cohérente sur toute la chaîne.

---

## 7. Jeu d'Essai

La fonctionnalité la plus représentative du projet est le scénario suivant :

> **enregistrer une base externe, y créer un schéma générique, puis l'interroger via le query-router sans écrire d'endpoint spécifique.**

### Vue synthétique du scénario

```mermaid
flowchart LR
    A[Register DB] --> B[Create Schema]
    B --> C[Insert Data]
    C --> D[Query Data]
    D --> E[Observe Isolation]
```

### Cas nominal

| #   | Données en entrée                                    | Données attendues                                    | Données obtenues          | Écart |
| --- | ---------------------------------------------------- | ---------------------------------------------------- | ------------------------- | ----- |
| 1   | Enregistrement d'une base PostgreSQL externe valide  | La base est stockée chiffrée dans `tenant_databases` | Conforme attendu          | Aucun |
| 2   | Création d'une table `contacts` via `schema-service` | Table créée avec `id`, `owner_id`, timestamps, RLS   | Conforme attendu          | Aucun |
| 3   | Insertion via `query-router`                         | Ligne créée, `owner_id` injecté automatiquement      | Conforme après correction | Aucun |
| 4   | Lecture par le même utilisateur                      | Retour des lignes propres à l'utilisateur            | Conforme                  | Aucun |
| 5   | Lecture par un autre utilisateur                     | Aucune fuite de lignes                               | Conforme                  | Aucun |

### Cas d'erreur

| #   | Données en entrée                    | Données attendues     | Données obtenues | Écart |
| --- | ------------------------------------ | --------------------- | ---------------- | ----- |
| 6   | Nom de table invalide                | Rejet avec erreur 400 | Conforme         | Aucun |
| 7   | Type SQL non supporté dans le schéma | Rejet avec erreur 400 | Conforme         | Aucun |
| 8   | Action inconnue dans `query-router`  | Rejet avec erreur 400 | Conforme         | Aucun |
| 9   | JWT absent                           | Refus d'accès         | Conforme         | Aucun |
| 10  | API key absente                      | Rejet par Kong        | Conforme         | Aucun |

### Analyse

Ce scénario démontre la valeur fondamentale du projet :

- la structure se crée sans code métier ;
- la sécurité n'est pas oubliée ;
- le moteur fonctionne pour différents projets ;
- l'exploitation reste unifiée.

---

## 8. Installation & Utilisation

### 8.1 Prérequis

Avant de démarrer :

- Docker Engine ;
- Docker Compose v2 ;
- Bash ;
- OpenSSL ;
- Node.js si l'on veut lancer les validations TypeScript hors conteneurs ;
- ports disponibles : `8000`, `5432`, `27017` et autres selon profils.

### 8.2 Installation

```bash
# 1. Cloner le dépôt
git clone <url-du-repo>
cd mini-baas-infra

# 2. Générer les variables d'environnement
bash scripts/generate-env.sh

# 3. (Optionnel) Installer les dépendances du monorepo NestJS
cd src
npm install
cd ..

# 4. Vérifier la configuration
bash scripts/validate-all.sh
```

### 8.3 Lancement du Projet

#### Démarrage du socle principal

```bash
make up
```

#### Démarrage avec services additionnels

```bash
make all-full
```

#### Vérification santé

```bash
make health
```

#### Logs

```bash
make logs
make logs SERVICE=kong
```

#### Arrêt

```bash
make down
```

### Ports et points d'accès usuels

| Service                            | URL / Port                    |
| ---------------------------------- | ----------------------------- |
| Gateway                            | `http://localhost:8000`       |
| PostgreSQL                         | `localhost:5432`              |
| MongoDB                            | `localhost:27017`             |
| Kong Admin                         | `localhost:8001`              |
| Prometheus (profile observability) | `http://localhost:9090`       |
| Grafana (profile observability)    | `http://localhost:3030`       |
| Studio (profile extras)            | selon profil et configuration |

### Ordre de démarrage recommandé pour une démonstration

1. générer `.env` ;
2. `make up` ;
3. vérifier la santé ;
4. créer un compte via `/auth/v1` ;
5. tester PostgREST ou mongo-api ;
6. enregistrer une base externe ;
7. créer un schéma ;
8. exécuter des requêtes génériques.

### 8.4 Séquence de démarrage service par service

Cette sous-partie explicite le démarrage du système comme une chaîne de dépendances. Dans une architecture distribuée, l'ordre de disponibilité n'est pas un détail : il conditionne la reproductibilité de l'environnement et la stabilité du lancement.

```mermaid
flowchart TD
  A[postgres] --> B[db-bootstrap]
  A --> C[gotrue]
  A --> D[postgrest]
  A --> E[permission-engine]
  A --> F[adapter-registry]
  A --> G[schema-service]

  H[mongo-keyfile] --> I[mongo]
  I --> J[mongo-init]
  I --> K[mongo-api]

  C --> L[kong]
  D --> L
  K --> L
  E --> L
  G --> L

  F --> M[query-router]
  L --> M
```

#### Étape 1 — préparation des secrets et variables d'environnement

Le système commence logiquement par la génération ou le chargement du fichier `.env`. Cette étape fixe :

- les mots de passe PostgreSQL ;
- le `JWT_SECRET` partagé ;
- les clés d'API Kong ;
- les secrets MinIO ;
- les paramètres MongoDB ;
- les tokens de service inter-services.

Sans cette couche, plusieurs conteneurs ne pourraient pas converger vers un état fonctionnel commun.

#### Étape 2 — démarrage des bases de persistance primaires

Les premières briques à démarrer sont `postgres` et `mongo` car elles supportent presque tous les autres services.

Rôle de `postgres` au démarrage :

- héberger les données de référence ;
- recevoir les rôles ;
- servir GoTrue, PostgREST, permission-engine et adapter-registry.

Rôle de `mongo` au démarrage :

- héberger les collections documentaires locales ;
- permettre le CRUD générique ;
- servir les change streams du realtime.

#### Étape 3 — jobs de bootstrap

Deux jobs transitoires sont critiques :

- `db-bootstrap` pour PostgreSQL ;
- `mongo-init` pour le replica set MongoDB.

`db-bootstrap` prépare notamment :

- le schéma `auth` ;
- les tables de démonstration ;
- les rôles `anon`, `authenticated`, `adapter_registry_role` ;
- les policies RLS ;
- les tables de registre et de permissions.

`mongo-init`, lui, garantit que le replica set existe, condition importante pour certaines fonctionnalités temps réel.

#### Étape 4 — services d'identité et de plan de données interne

Quand PostgreSQL est prêt et initialisé, plusieurs services peuvent démarrer :

- `gotrue` ;
- `postgrest` ;
- `permission-engine` ;
- `adapter-registry` ;
- `schema-service`.

Quand MongoDB est prêt :

- `mongo-api` devient disponible.

#### Étape 5 — gateway et exposition unifiée

Kong ne devient réellement utile qu'une fois ses upstreams clés joignables. Son démarrage tardif dans la chaîne évite d'exposer une façade vide ou incohérente.

#### Étape 6 — services dépendant de la gateway ou d'autres services internes

Le `query-router` dépend à la fois :

- du registre d'adaptateurs ;
- de la disponibilité de la chaîne de routage ;
- du token de service.

Son positionnement en fin de séquence est cohérent.

#### Étape 7 — services optionnels et observabilité

Les services `minio`, `storage-router`, `prometheus`, `grafana`, `loki`, `promtail`, `studio`, `pg-meta`, `supavisor`, `trino` s'ajoutent ensuite selon les profils activés.

### 8.5 Cycle complet des requêtes principales

Cette section documente le comportement bout en bout pour les principaux flux techniques. Elle est particulièrement utile en soutenance pour montrer que l'on comprend non seulement les composants, mais aussi leur articulation dynamique.

#### 8.5.1 Cycle d'une requête SQL via PostgREST

```mermaid
sequenceDiagram
  participant C as Client
  participant K as Kong
  participant G as JWT plugin
  participant P as PostgREST
  participant DB as PostgreSQL

  C->>K: GET /rest/v1/projects + apikey + Bearer JWT
  K->>G: Vérification JWT
  G-->>K: Claims valides
  K->>P: Forward request with auth context
  P->>DB: Requête SQL générée
  DB-->>P: Résultats filtrés par RLS
  P-->>K: JSON REST
  K-->>C: Réponse
```

**Analyse :** ici, la logique applicative de base ne vit pas dans un contrôleur NestJS. Le couplage API-table est fourni par PostgREST, et la sécurité de ligne est portée par PostgreSQL.

#### 8.5.2 Cycle d'une requête MongoDB via `mongo-api`

```mermaid
sequenceDiagram
  participant C as Client
  participant K as Kong
  participant M as mongo-api
  participant DB as MongoDB

  C->>K: POST /mongo/v1/collections/orders/documents
  K->>M: Headers utilisateur injectés
  M->>M: Validation DTO + AuthGuard
  M->>M: Injection owner_id + nettoyage payload
  M->>DB: insertOne / find / update / delete
  DB-->>M: Résultat
  M-->>K: Réponse normalisée
  K-->>C: Réponse finale
```

**Analyse :** ici, contrairement à PostgREST, la couche de protection propriétaire est assurée dans le service applicatif lui-même.

#### 8.5.3 Cycle d'une requête sur base externe via `query-router`

```mermaid
sequenceDiagram
  participant C as Client
  participant K as Kong
  participant QR as query-router
  participant AR as adapter-registry
  participant E as SQL/Mongo engine
  participant X as External DB

  C->>K: POST /query/v1/query/:dbId/tables/:table
  K->>QR: user headers + service context
  QR->>AR: resolve database connection
  AR-->>QR: engine + decrypted connection string
  QR->>E: execute(action, data, filter, userId)
  E->>X: safe operation on external DB
  X-->>E: result set
  E-->>QR: normalized response
  QR-->>K: API response
  K-->>C: final response
```

**Analyse :** ce flux est la démonstration la plus forte du caractère générique du projet, car il permet de manipuler une base distante sans créer de back-end dédié.

#### 8.5.4 Cycle de création de schéma via `schema-service`

```mermaid
sequenceDiagram
  participant C as Client
  participant K as Kong
  participant SS as schema-service
  participant AR as adapter-registry
  participant X as External DB
  participant PG as schema_registry

  C->>K: POST /schemas/v1/schemas
  K->>SS: validated user request
  SS->>AR: fetch external DB connection
  AR-->>SS: engine + connection string
  SS->>X: CREATE TABLE / CREATE COLLECTION
  SS->>PG: Persist schema metadata
  SS-->>K: created result
  K-->>C: confirmation
```

#### 8.5.5 Cycle de stockage objet via `storage-router`

```mermaid
sequenceDiagram
  participant C as Client
  participant K as Kong
  participant S as storage-router
  participant O as MinIO / S3

  C->>K: POST /storage/v1/sign/:bucket/*
  K->>S: authenticated request
  S->>S: prefix path with user id
  S->>O: generate presigned operation
  O-->>S: signed URL
  S-->>C: signedUrl + expiresAt
  C->>O: upload/download directly
```

**Analyse :** le back-end ne transporte pas le fichier lui-même dans ce flux ; il délègue le transfert au stockage objet via une autorisation temporaire.

#### 8.5.6 Cycle d'envoi d'email via `email-service`

```mermaid
sequenceDiagram
  participant C as Client
  participant K as Kong
  participant E as email-service
  participant SMTP as SMTP server

  C->>K: POST /email/v1/send
  K->>E: authenticated request
  E->>E: validate dto
  E->>SMTP: sendMail()
  SMTP-->>E: messageId
  E-->>C: message accepted
```

#### 8.5.7 Cycle temps réel

```mermaid
sequenceDiagram
  participant C as Client
  participant K as Kong
  participant R as realtime
  participant PG as PostgreSQL
  participant MG as MongoDB

  C->>K: subscribe websocket/http realtime
  K->>R: forward connection
  R->>PG: watch relational changes
  R->>MG: watch document changes
  PG-->>R: event
  MG-->>R: event
  R-->>C: pushed change notification
```

**Analyse :** ce flux transforme le backend en plateforme réactive, et non seulement transactionnelle.

---

## 9. Risques, Limites & Améliorations Futures

### 9.1 Risques techniques actuels

| Risque                         | Description                                                      | Impact potentiel                  | Réponse actuelle / future                                |
| ------------------------------ | ---------------------------------------------------------------- | --------------------------------- | -------------------------------------------------------- |
| Complexité de pile             | Multiplication des services à comprendre et exploiter            | Courbe d'apprentissage plus forte | Documentation, Makefile, profils Compose                 |
| Couplage au gateway            | Beaucoup de flux supposent Kong disponible                       | Dégradation globale si Kong tombe | Healthchecks, config déclarative, supervision            |
| Gouvernance des bases externes | Une mauvaise base externe peut avoir des conventions inattendues | Difficulté de normalisation       | `schema-service`, validation des types, registre central |
| Hétérogénéité SQL/Mongo        | Deux modèles de données impliquent deux stratégies de sécurité   | Complexité de raisonnement        | Encapsulation par moteurs dédiés                         |
| Surface d'exposition générique | Un backend réutilisable expose des primitives puissantes         | Risques d'abus si mal gouverné    | API keys, JWT, rate limits, policies                     |

### 9.2 Limites fonctionnelles

- absence d'interface d'administration unifiée dédiée aux services custom ;
- support limité volontairement à certaines opérations génériques ;
- dépendance aux conventions `owner_id` pour une partie des stratégies d'isolation ;
- pas de moteur GraphQL générique custom à ce stade ;
- pas de workflow low-code complet de gestion fonctionnelle ;
- pas de haute disponibilité multi-nœuds décrite dans ce dépôt.

### 9.3 Limites pédagogiques à expliciter à l'oral

Pour un exercice, il peut être utile de préciser que :

- la plateforme vise d'abord la démonstration d'architecture et d'intégration ;
- elle est déjà très riche, mais tout n'est pas industrialisé au niveau d'un SaaS mondial ;
- le but n'est pas de remplacer tous les développements métiers, mais de réduire massivement les développements répétitifs.

### 9.4 Améliorations futures envisageables

| Axe                  | Amélioration                                                             |
| -------------------- | ------------------------------------------------------------------------ |
| Gouvernance          | UI dédiée pour `adapter-registry`, `schema-service`, `permission-engine` |
| Sécurité             | rotation automatisée des secrets, audit trail plus poussé                |
| Data plane           | support d'autres moteurs ou d'opérations analytiques enrichies           |
| Developer experience | SDK client officiel, templates front-end de consommation                 |
| Observabilité        | corrélation distribuée complète et dashboards spécialisés                |
| Déploiement          | packaging Kubernetes / Helm / GitOps                                     |
| Documentation        | guides orientés par cas d'usage métier                                   |

### 9.5 Synthèse stratégique

Le principal compromis du projet est le suivant :

> il accepte une complexité d'infrastructure plus élevée pour réduire de façon radicale la répétition des développements back-end sur les futurs projets.

Ce compromis est cohérent si la plateforme est pensée comme un investissement transversal.

---

## 10. Glossaire

| Terme              | Définition                                                                          |
| ------------------ | ----------------------------------------------------------------------------------- |
| BaaS               | Backend as a Service, plateforme fournissant des briques back-end mutualisées       |
| RLS                | Row-Level Security, mécanisme PostgreSQL de sécurité ligne par ligne                |
| DTO                | Data Transfer Object, structure validée de données entrantes/sortantes              |
| JWT                | JSON Web Token, jeton d'authentification signé                                      |
| API Gateway        | Point d'entrée unique qui applique politiques, routage et sécurité                  |
| Tenant             | Entité logique isolée dans un système multi-tenant                                  |
| ABAC               | Attribute-Based Access Control, autorisation basée sur des attributs                |
| RBAC               | Role-Based Access Control, autorisation basée sur des rôles                         |
| Presigned URL      | URL temporaire signée donnant un accès limité à un objet de stockage                |
| Change Stream      | Flux d'événements de changements côté MongoDB                                       |
| Declarative config | Configuration décrite dans un fichier plutôt que construite dynamiquement à la main |
| Monorepo           | Dépôt unique contenant plusieurs applications et bibliothèques                      |
| Healthcheck        | Vérification d'état d'un service par l'orchestrateur                                |
| Upstream           | Service cible derrière la gateway                                                   |
| Owner isolation    | Stratégie consistant à filtrer les données par propriétaire                         |

---

## 11. Structure du Projet

```text
mini-baas-infra/
│
├── docker-compose.yml                # orchestration principale
├── docker-bake.hcl                   # build multi-targets
├── Makefile                          # commandes d'exploitation
├── README.md                         # documentation racine
├── docs/                             # documentation détaillée
├── config/                           # configs observabilité
├── docker/                           # contrats et services Docker spécifiques
├── scripts/                          # bootstrap, tests, validations, migrations
│
├── src/                              # monorepo NestJS
│   ├── Dockerfile                    # Dockerfile unifié des apps
│   ├── nest-cli.json                 # définition monorepo
│   ├── tsconfig.json                 # config TypeScript
│   ├── apps/
│   │   ├── adapter-registry/
│   │   ├── query-router/
│   │   ├── schema-service/
│   │   ├── permission-engine/
│   │   ├── mongo-api/
│   │   ├── storage-router/
│   │   └── email-service/
│   └── libs/
│       ├── common/
│       ├── database/
│       └── health/
│
└── playground/                       # sandbox éventuel de démonstration
```

### Lecture de structure par responsabilités

| Dossier           | Responsabilité                               |
| ----------------- | -------------------------------------------- |
| `src/apps`        | logique applicative des microservices custom |
| `src/libs`        | composants réutilisables transverses         |
| `docker/services` | services ou configurations d'infrastructure  |
| `scripts`         | automatisation et validation                 |
| `docs`            | capitalisation documentaire                  |
| `config`          | observabilité et provisioning                |

---

## 12. Cartographie des Fichiers Sources

Cette cartographie relie les principaux fichiers du dépôt à leur rôle architectural. Elle a une double utilité :

- faciliter la soutenance en montrant où vit chaque responsabilité ;
- accélérer la maintenance en donnant une lecture orientée architecture.

### 12.1 Cartographie des applications NestJS

| Fichier                                                                | Rôle architectural                               |
| ---------------------------------------------------------------------- | ------------------------------------------------ |
| `src/apps/adapter-registry/src/main.ts`                                | bootstrap HTTP, logger, Swagger, pipeline global |
| `src/apps/adapter-registry/src/app.module.ts`                          | composition racine du service registre           |
| `src/apps/adapter-registry/src/health.controller.ts`                   | santé du service                                 |
| `src/apps/adapter-registry/src/crypto/crypto.module.ts`                | exposition du composant de chiffrement           |
| `src/apps/adapter-registry/src/crypto/crypto.service.ts`               | chiffrement/déchiffrement AES-256-GCM            |
| `src/apps/adapter-registry/src/databases/databases.module.ts`          | module fonctionnel du registre                   |
| `src/apps/adapter-registry/src/databases/databases.controller.ts`      | endpoints d'enregistrement / lecture des bases   |
| `src/apps/adapter-registry/src/databases/databases.service.ts`         | logique métier du registre et stockage chiffré   |
| `src/apps/adapter-registry/src/databases/dto/register-database.dto.ts` | contrat de validation d'enregistrement           |
| `src/apps/query-router/src/main.ts`                                    | bootstrap du routeur de requêtes                 |
| `src/apps/query-router/src/app.module.ts`                              | assemblage du service                            |
| `src/apps/query-router/src/health.controller.ts`                       | santé du query-router                            |
| `src/apps/query-router/src/query/query.module.ts`                      | module fonctionnel de requêtage                  |
| `src/apps/query-router/src/query/query.controller.ts`                  | endpoints d'exécution et de listing              |
| `src/apps/query-router/src/query/query.service.ts`                     | orchestration du registre et des engines         |
| `src/apps/query-router/src/query/dto/query.dto.ts`                     | contrat unifié des opérations de requêtage       |
| `src/apps/query-router/src/engines/postgresql.engine.ts`               | moteur PostgreSQL générique sécurisé             |
| `src/apps/query-router/src/engines/mongodb.engine.ts`                  | moteur MongoDB générique sécurisé                |
| `src/apps/schema-service/src/main.ts`                                  | bootstrap du service de schéma                   |
| `src/apps/schema-service/src/app.module.ts`                            | assemblage racine                                |
| `src/apps/schema-service/src/health.controller.ts`                     | santé du service                                 |
| `src/apps/schema-service/src/schemas/schemas.module.ts`                | module métier de schémas                         |
| `src/apps/schema-service/src/schemas/schemas.controller.ts`            | endpoints de création/listing/suppression        |
| `src/apps/schema-service/src/schemas/schemas.service.ts`               | orchestration DDL et registre                    |
| `src/apps/schema-service/src/schemas/dto/schema.dto.ts`                | définition des schémas entrants                  |
| `src/apps/schema-service/src/engines/postgres-schema.engine.ts`        | création/suppression de tables PostgreSQL        |
| `src/apps/schema-service/src/engines/mongo-schema.engine.ts`           | création/suppression de collections MongoDB      |
| `src/apps/permission-engine/src/main.ts`                               | bootstrap du moteur de permissions               |
| `src/apps/permission-engine/src/app.module.ts`                         | composition du service                           |
| `src/apps/permission-engine/src/health.controller.ts`                  | santé du service                                 |
| `src/apps/permission-engine/src/permissions/permissions.module.ts`     | module d'évaluation des permissions              |
| `src/apps/permission-engine/src/permissions/permissions.controller.ts` | endpoints de vérification et de rôles            |
| `src/apps/permission-engine/src/permissions/permissions.service.ts`    | logique de vérification ABAC/RBAC                |
| `src/apps/permission-engine/src/permissions/dto/permission.dto.ts`     | DTO de check et d'affectation                    |
| `src/apps/permission-engine/src/policies/policies.module.ts`           | module de gestion des policies                   |
| `src/apps/permission-engine/src/policies/policies.controller.ts`       | endpoints CRUD de policies                       |
| `src/apps/permission-engine/src/policies/policies.service.ts`          | persistance et lecture des policies              |
| `src/apps/permission-engine/src/policies/dto/policy.dto.ts`            | contrat des policies                             |
| `src/apps/mongo-api/src/main.ts`                                       | bootstrap du data plane Mongo                    |
| `src/apps/mongo-api/src/app.module.ts`                                 | composition globale Mongo                        |
| `src/apps/mongo-api/src/health.controller.ts`                          | santé du service                                 |
| `src/apps/mongo-api/src/collections/collections.module.ts`             | module CRUD documentaire                         |
| `src/apps/mongo-api/src/collections/collections.controller.ts`         | endpoints CRUD collections                       |
| `src/apps/mongo-api/src/collections/collections.service.ts`            | logique owner-scoped Mongo                       |
| `src/apps/mongo-api/src/collections/dto/collection.dto.ts`             | DTOs documentaires                               |
| `src/apps/mongo-api/src/admin/admin.module.ts`                         | module d'administration Mongo                    |
| `src/apps/mongo-api/src/admin/admin.controller.ts`                     | endpoints admin collection/schema/index          |
| `src/apps/mongo-api/src/admin/admin.service.ts`                        | gestion validateurs et index                     |
| `src/apps/mongo-api/src/admin/dto/admin.dto.ts`                        | DTOs admin Mongo                                 |
| `src/apps/storage-router/src/main.ts`                                  | bootstrap du service de storage                  |
| `src/apps/storage-router/src/app.module.ts`                            | composition du service                           |
| `src/apps/storage-router/src/health.controller.ts`                     | santé du service                                 |
| `src/apps/storage-router/src/storage/storage.module.ts`                | module fonctionnel storage                       |
| `src/apps/storage-router/src/storage/storage.controller.ts`            | endpoint de présignature                         |
| `src/apps/storage-router/src/storage/storage.service.ts`               | génération des URLs signées                      |
| `src/apps/storage-router/src/storage/dto/presign.dto.ts`               | contrat de présignature                          |
| `src/apps/email-service/src/main.ts`                                   | bootstrap du service email                       |
| `src/apps/email-service/src/app.module.ts`                             | composition racine                               |
| `src/apps/email-service/src/health.controller.ts`                      | santé du service                                 |
| `src/apps/email-service/src/mail/mail.module.ts`                       | module email                                     |
| `src/apps/email-service/src/mail/mail.controller.ts`                   | endpoint d'envoi                                 |
| `src/apps/email-service/src/mail/mail.service.ts`                      | intégration SMTP                                 |
| `src/apps/email-service/src/mail/dto/send-email.dto.ts`                | contrat d'envoi d'email                          |

### 12.2 Cartographie des bibliothèques partagées

| Fichier                                                          | Rôle architectural                                    |
| ---------------------------------------------------------------- | ----------------------------------------------------- |
| `src/libs/common/src/index.ts`                                   | barrel export du socle commun                         |
| `src/libs/common/src/decorators/current-user.decorator.ts`       | extraction du contexte utilisateur                    |
| `src/libs/common/src/guards/auth.guard.ts`                       | validation des headers utilisateurs injectés par Kong |
| `src/libs/common/src/guards/roles.guard.ts`                      | enforcement des rôles                                 |
| `src/libs/common/src/guards/service-token.guard.ts`              | auth inter-services ou fallback utilisateur           |
| `src/libs/common/src/interfaces/user-context.interface.ts`       | type commun du contexte utilisateur                   |
| `src/libs/common/src/config/env.validation.ts`                   | validation de configuration                           |
| `src/libs/common/src/filters/all-exceptions.filter.ts`           | normalisation des erreurs                             |
| `src/libs/common/src/interceptors/correlation-id.interceptor.ts` | propagation des IDs de corrélation                    |
| `src/libs/common/src/pipes/validation.pipe.ts`                   | politique globale de validation DTO                   |
| `src/libs/database/src/index.ts`                                 | exports du socle base de données                      |
| `src/libs/database/src/postgres/postgres.module.ts`              | module PostgreSQL partagé                             |
| `src/libs/database/src/postgres/postgres.service.ts`             | pools PostgreSQL, adminQuery, tenantQuery             |
| `src/libs/database/src/mongo/mongo.module.ts`                    | module Mongo partagé                                  |
| `src/libs/database/src/mongo/mongo.service.ts`                   | client Mongo mutualisé                                |
| `src/libs/health/src/index.ts`                                   | exports santé                                         |
| `src/libs/health/src/health.module.ts`                           | module de health dynamique                            |
| `src/libs/health/src/health.controller.ts`                       | endpoints live/ready standardisés                     |

### 12.3 Cartographie des fichiers d'infrastructure majeurs

| Fichier                              | Rôle architectural                                 |
| ------------------------------------ | -------------------------------------------------- |
| `docker-compose.yml`                 | orchestration globale de la plateforme             |
| `docker-bake.hcl`                    | stratégie de build parallèle multi-images          |
| `Makefile`                           | façade d'exploitation développeur / ops            |
| `scripts/db-bootstrap.psql`          | initialisation structurante de PostgreSQL          |
| `scripts/generate-env.sh`            | génération sécurisée du `.env`                     |
| `scripts/validate-all.sh`            | validation locale rapide avant exécution ou commit |
| `docker/services/kong/conf/kong.yml` | définition déclarative de la gateway               |
| `src/Dockerfile`                     | build unifié des microservices NestJS              |
| `src/nest-cli.json`                  | définition du monorepo Nest                        |
| `src/tsconfig.json`                  | base TypeScript commune                            |

### 12.4 Cartographie documentaire et opérationnelle

| Fichier / dossier                                  | Rôle architectural              |
| -------------------------------------------------- | ------------------------------- |
| `docs/README.md`                                   | index documentaire              |
| `docs/Insfrastructure.md`                          | vue d'ensemble d'infrastructure |
| `docs/Kong-Gateway-Configuration.md`               | détail du gateway               |
| `docs/Kong-Database-Authentication-Integration.md` | chaîne auth/RLS                 |
| `docs/Mongo-Service-Validation.md`                 | validation du data plane Mongo  |
| `docs/Partner-Demo-Runbook.md`                     | scénario de démonstration       |
| `config/prometheus/`                               | configuration métriques         |
| `config/grafana/`                                  | provisioning dashboards         |
| `config/loki/`                                     | configuration logs              |
| `config/promtail/`                                 | collecte des logs Docker        |

---

## 13. Annexes

### Annexe A – Diagramme complet du cycle d'authentification

```mermaid
sequenceDiagram
    participant U as Utilisateur
    participant FE as Front-end
    participant K as Kong
    participant GT as GoTrue
    participant API as Services
    participant PG as PostgreSQL / MongoDB

    U->>FE: Saisie email + mot de passe
    FE->>K: POST /auth/v1/token
    K->>GT: Forward auth request
    GT-->>FE: access token + refresh token
    FE->>K: Requête API avec apikey + Bearer JWT
    K->>K: key-auth + jwt validation
    K->>API: Injecte X-User-Id / X-User-Role
    API->>PG: Requête sécurisée
    PG-->>API: Données filtrées
    API-->>FE: Réponse JSON
```

### Annexe B – Cycle de création d'un schéma externe

```mermaid
sequenceDiagram
    participant U as User
    participant SS as schema-service
    participant AR as adapter-registry
    participant DB as External DB
    participant REG as schema_registry

    U->>SS: POST /schemas with CreateSchemaDto
    SS->>AR: GET /databases/:id/connect
    AR-->>SS: engine + connection_string
    SS->>DB: CREATE TABLE / CREATE COLLECTION
    SS->>REG: INSERT metadata in schema_registry
    SS-->>U: Schema created
```

### Annexe C – Cycle de requête universelle

```mermaid
sequenceDiagram
    participant U as User
    participant QR as query-router
    participant AR as adapter-registry
    participant ENG as Engine SQL/Mongo
    participant DB as External Database

    U->>QR: POST query request
    QR->>AR: fetchConnection(dbId, userId)
    AR-->>QR: engine + decrypted connection string
    QR->>ENG: execute(action, filter, data, userId)
    ENG->>DB: parameterized query / filtered document op
    DB-->>ENG: result set
    ENG-->>QR: normalized payload
    QR-->>U: rows + rowCount
```

### Annexe D – Extrait de DTO unifié pour le query-router

```typescript
export class ExecuteQueryDto {
  @IsEnum([
    "select",
    "insert",
    "update",
    "delete",
    "find",
    "insertOne",
    "updateMany",
    "deleteMany",
  ])
  action!: string;

  @IsOptional()
  @IsObject()
  data?: Record<string, unknown>;

  @IsOptional()
  @IsObject()
  filter?: Record<string, unknown>;
}
```

Ce DTO illustre la logique de standardisation : une enveloppe commune, plusieurs moteurs.

### Annexe E – Pourquoi ce projet est une architecture back-end généraliste

Le projet mérite l'étiquette de **backend généraliste** pour les raisons suivantes :

1. il n'est pas lié à un métier particulier ;
2. il fournit des primitives universelles (auth, data, storage, email, realtime) ;
3. il peut être branché à plusieurs projets différents ;
4. il supporte plusieurs moteurs de persistance ;
5. il crée les schémas et interroge les bases sans endpoint spécifique ;
6. il applique des règles génériques de sécurité ;
7. il est industrialisable grâce à Docker Compose et à ses scripts.

### Annexe F – Conclusion générale

Cette architecture n'est pas seulement une pile technique de services juxtaposés. C'est un **système cohérent**, pensé comme une usine à backends :

- le gateway protège et normalise ;
- l'authentification unifie l'identité ;
- les data planes exposent les données sans code métier répétitif ;
- le registre, le routeur de requêtes et le générateur de schémas rendent la plateforme adaptable à d'autres projets ;
- le moteur de permissions apporte la gouvernance ;
- les services transverses couvrent les besoins courants ;
- les outils d'observabilité et d'automatisation rendent l'ensemble exploitable.

En résumé, cette solution constitue une **fondation technique fortement réutilisable**, sécurisée et modulaire, capable de servir de back-end à de très nombreux projets sans repartir de zéro.

---

_Document rédigé dans le cadre d'un exercice d'architecture et de documentation technique._
_Version basée sur l'état du dépôt au 12 avril 2026._
