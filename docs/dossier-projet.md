# DOSSIER DE PROJET

## Développeur web et web mobile

## LESIEUR DYLAN

## TABLE DES MATIÈRES

1. [DOSSIER DE PROJET](#dossier-de-projet)
2. [TABLE DES MATIÈRES](#table-des-matières)
3. [CHAPITRE 1. Synthèse des compétences mobilisées]
4. [CHAPITRE 2. Présentation du projet]
5. [CHAPITRE 3. Les réalisations personnelles, front-end (React / SCSS)]
6. [CHAPITRE 4. Les réalisations personnelles, back-end (Node.js / Express / MongoDB / POSTGRESQL)]
7. [CHAPITRE 5. Eléments de sécurité de l'application]
8. [CHAPITRE 6. Jeu d'essai]
9. [CHAPITRE 8. Conclusion]
10. [Annexes]

## CHAPITRE 1. Synthèse des compétences mobilisées

La réalisation du projet **Prismatica**, une application de gestion de bases de données et de création de dashboards pour les entreprises, a mobilisé un large éventail de compétences techniques et méthodologiques. Mon intervention a porté sur la conception d'une solution robuste, sécurisée et optimisée pour un usage professionnel principalement desktop.

Mon travail s'est réparti entre la conception d'interfaces utilisateur, la mise en place de l'infrastructure de données, la définition des règles de sécurité et la construction d'une logique back-end générique capable de soutenir plusieurs cas d'usage métier.

> Activité type n°1 : Développer la partie front-end d'une application web ou web mobile sécurisée.

**Conception des interfaces utilisateur (maquetter)** : j'ai initié le projet par la création de maquettes et de parcours utilisateurs. Ces supports ont permis de définir l'expérience utilisateur, la hiérarchie des écrans et les interactions principales : création de collections, configuration de vues, composition de dashboards et gestion des permissions. Dans le contexte de Prismatica, une approche **desktop first** a été privilégiée, car l'application manipule des tableaux, graphiques, formulaires complexes et interfaces de configuration qui sont plus adaptés à un écran large. Le responsive design reste néanmoins prévu afin de permettre la consultation et certains usages simples sur tablette ou mobile.

**Intégration des interfaces statiques (réaliser)** : j'ai structuré l'application avec du HTML sémantique et du SCSS afin d'obtenir une base lisible, maintenable et cohérente. Les composants ont été pensés pour être réutilisables : cartes, tableaux, formulaires, panneaux latéraux, modales et widgets de dashboard.

**Développement de l'interactivité (développer la partie dynamique)** : j'ai utilisé **React** pour rendre l'interface dynamique. Mon rôle a consisté à gérer les appels asynchrones vers l'API, les états de chargement, les formulaires réactifs, les retours d'erreur, les mises à jour conditionnelles de l'interface et la préparation des interactions nécessaires au builder de données et de dashboards.

> Activité type n°2 : Développer la partie back-end d'une application web ou web mobile sécurisée.

BaaS signifie **Backend as a Service**. Il s'agit d'une infrastructure back-end préconfigurée qui fournit des briques communes : authentification, stockage, API, permissions, temps réel, fichiers, emails et observabilité. Dans Prismatica, cette approche permet de concentrer l'effort produit sur la gestion des données et l'expérience utilisateur, tout en s'appuyant sur une plateforme technique réutilisable. J'ai structuré le back-end comme une **usine à backends génériques**, capable de fournir des services standardisés sans recoder une API métier complète pour chaque nouveau projet.

| Membre | Rôle principal | Responsabilités observées / déduites |
| ------ | -------------- | ------------------------------------ |

| dlesieur | Product Owner / Tech Lead / DevOps / Back-End Lead | Conception de l'architecture, intégration Docker, orchestration des services, sécurité, écriture des services NestJS, outillage d'exploitation, documentation technique |

**Modélisation de la base de données** J'ai conçu le schéma de la base de données relationnelle **PostgreSQL** pour stocker les données de l'application, en veillant à la normalisation et à l'optimisation des requêtes. J'ai également utilisé **MongoDB** pour certaines fonctionnalités nécessitant une flexibilité accrue dans la gestion des données. La modélisation a permis de structurer les données de manière efficace, facilitant ainsi les opérations de lecture et d'écriture en définissant des relations claires entre les différentes entités de l'application et les contraintes d'intégrité.

**Élaboration des composants d'accès aux données** : j'ai développé des composants permettant d'interagir avec les bases de données à travers des services contrôlés. La gateway `Kong` centralise les accès publics, tandis que les services internes appliquent les permissions et routent les requêtes vers PostgreSQL, MongoDB ou les adapters nécessaires. Des mécanismes de cache et de supervision ont également été intégrés pour améliorer la performance et la fiabilité. Le moteur `Trino` est réservé aux usages analytiques et aux requêtes fédérées, afin de ne pas alourdir le chemin critique des opérations CRUD.

## CHAPITRE 2. Présentation du projet

### Présentation de l'entreprise

Le projet **Prismatica** s'inscrit dans le contexte de **NovaSphere**, une société de conseil composée de développeurs et de designers qui accompagne des clients aux besoins métiers variés : logistique, marketing, restauration, services, opérations internes ou suivi commercial. Ces organisations partagent une difficulté commune : leurs données sont dispersées entre des tableurs, des outils propriétaires, des applications vieillissantes ou des bases de données sans interface réellement exploitable par les équipes métier.

NovaSphere construisait jusqu'ici des tableaux de bord et des interfaces spécifiques pour chaque client. Cette approche devenait coûteuse, difficile à maintenir et peu scalable. L'objectif de Prismatica est donc de créer une plateforme générique permettant de transformer des données brutes en espaces de travail visuels, dashboards, vues métiers et interfaces web réutilisables.

Dans ce projet, mon rôle a été de concevoir une solution capable de répondre à deux enjeux complémentaires :

- offrir une interface de gestion de données compréhensible par des utilisateurs non développeurs ;
- fournir une infrastructure back-end robuste, sécurisée et réutilisable, capable de supporter des données relationnelles, documentaires, temps réel et des règles d'accès avancées.

Prismatica n'est donc pas seulement un outil de visualisation. C'est une application de **database management orientée métier** : elle permet de créer des collections, de structurer des champs, de visualiser les informations sous plusieurs formes, de composer des dashboards et de publier certaines vues dans une page web ou dans un espace applicatif autonome.

L'infrastructure mini-BaaS développée autour du projet apporte la couche technique nécessaire : authentification, API gateway, base relationnelle, base documentaire, permissions, routage des requêtes, stockage, observabilité et déploiement Dockerisé.

### Cahier des charges du projet

#### contexte et objectifs

Le projet **Prismatica** vise à développer une application web permettant aux entreprises de créer, organiser, visualiser et exploiter leurs données sans dépendre systématiquement d'un développeur pour chaque modification d'interface, de structure ou de tableau de bord.

Le besoin initial vient d'un constat fréquent en entreprise : les équipes métier manipulent quotidiennement des informations importantes, mais ces informations sont souvent stockées dans des outils non reliés entre eux. Les données peuvent être présentes dans des fichiers CSV, des tableurs, des exports logiciels, des bases SQL, des documents ou des applications internes anciennes. Cette fragmentation rend les processus plus lents, complique la collaboration et limite la capacité à produire des dashboards fiables.

Prismatica répond à ce problème avec une interface web visuelle et user-friendly. L'utilisateur peut créer un projet, définir ses collections comme dans une base de données, ajouter des champs typés, importer des données, construire des vues, composer des dashboards et publier certaines interfaces sous forme de page autonome ou de composant intégré dans un site existant.

Le positionnement est volontairement hybride :

- une couche **database management** pour structurer les données ;
- une couche **CMS métier** pour créer des interfaces adaptées à un usage opérationnel ;
- une couche **dashboarding** pour visualiser les indicateurs ;
- une couche **adapter/embed** pour exposer une vue, un formulaire, un endpoint ou un widget à l'extérieur ;
- une couche **permissions** pour contrôler précisément qui peut voir, modifier, publier ou administrer chaque ressource.

L'enjeu principal est l'autonomie. Un manager, un responsable métier ou un collaborateur formé doit pouvoir faire évoluer son espace de travail, ajouter un tableau, modifier une vue, filtrer des données ou publier un dashboard sans attendre une intervention technique lourde. Les développeurs restent nécessaires pour l'infrastructure, les intégrations complexes et la sécurité, mais les ajustements métier courants deviennent accessibles aux utilisateurs autorisés.

Les objectifs du projet sont donc les suivants :

- centraliser les données d'un projet ou d'une équipe dans un espace sécurisé ;
- permettre la création de schémas de données visuels et compréhensibles ;
- proposer plusieurs représentations d'une même donnée : tableau, graphique, KPI, calendrier, kanban ou carte ;
- créer rapidement des dashboards utilisables en interne, en démonstration client ou intégrés dans une page web ;
- rendre les utilisateurs métier plus autonomes dans l'organisation de leurs données ;
- garantir la traçabilité, la sécurité et la séparation des accès ;
- fournir une base technique réutilisable pour d'autres applications métiers.

#### objectifs du projet et choix architecturaux

Le projet poursuit un objectif produit et un objectif technique.

Sur le plan produit, Prismatica doit permettre de créer des applications de données rapidement : un utilisateur définit un modèle, crée des vues, assemble une interface, partage un dashboard et forme ses collègues à l'utiliser. La même donnée peut servir plusieurs usages sans duplication : suivi interne, reporting direction, widget public, formulaire, export ou API.

Sur le plan technique, le back-end ne devait pas être limité à un seul métier ou à un seul modèle de données. Il devait rester générique, sécurisé et extensible. C'est pourquoi l'architecture a été pensée comme une plateforme **BaaS** auto-hébergée, orientée Docker Compose, capable de fournir des briques réutilisables : authentification, données relationnelles, données documentaires, requêtage multi-tenant, temps réel, stockage objet, email transactionnel, logs, métriques et politiques de sécurité unifiées.

Les principes retenus sont les suivants :

- le SDK et l'interface front-end expriment une intention utilisateur ;
- la gateway sécurise l'entrée publique et applique les contrôles transverses ;
- le back-end reste l'autorité pour les permissions et l'exécution des requêtes ;
- le `query-router` orchestre les accès SQL/NoSQL sans exposer directement les bases ;
- le `permission-engine` applique les règles RBAC/ABAC côté serveur ;
- l'`adapter-registry` conserve les métadonnées nécessaires aux connexions et aux mappings ;
- PostgreSQL porte les données relationnelles et les contrôles forts ;
- MongoDB peut porter les données documentaires ou analytiques ;
- Trino est réservé aux usages analytiques et fédérés, pas au CRUD transactionnel ;
- Docker Compose permet de lancer les plans de service selon leur criticité.

Ce découpage évite que la logique de sécurité soit placée côté client. Il permet aussi de rendre la plateforme réutilisable : Prismatica devient une application construite sur mini-BaaS, mais mini-BaaS peut également servir de base à d'autres produits métiers.

#### Architectures logicielles et choix techniques

L'architecture applicative repose sur une séparation claire entre l'expérience utilisateur, l'API publique, les services privés et les plans de données. Cette organisation permet de garder une interface simple côté utilisateur tout en conservant une plateforme robuste côté infrastructure.

Le parcours général est le suivant :

```mermaid
flowchart LR
  U[Utilisateur Prismatica] --> F[Interface web]
  F --> S[SDK / API publique]
  S --> K[Kong Gateway]
  K --> A[Services applicatifs privés]
  A --> P[(PostgreSQL)]
  A --> M[(MongoDB)]
  A --> R[(Redis)]
  A --> O[(Stockage objet)]
```

Les choix techniques principaux sont :

- **React / SCSS** pour construire une interface dynamique, responsive et adaptée aux usages desktop complexes ;
- **Node.js / TypeScript / NestJS** pour développer des services back-end modulaires ;
- **Kong Gateway** pour centraliser les routes publiques, l'authentification, le rate limiting et les contrôles transverses ;
- **PostgreSQL** pour les données relationnelles, les règles fortes, les schémas et les contrôles d'intégrité ;
- **MongoDB** pour certains usages documentaires, analytiques ou flexibles ;
- **Redis** pour le cache, les files ou les usages temps réel légers ;
- **MinIO** pour le stockage objet compatible S3 ;
- **Prometheus, Grafana, Loki et Promtail** pour l'observabilité ;
- **Docker Compose** pour orchestrer l'ensemble des services de manière reproductible.

La pile est divisée en plans de criticité. Le cœur BaaS contient les services indispensables : gateway, authentification, PostgreSQL, PostgREST, Realtime et Redis. Les plans adapter, control, data, analytics, background et observability peuvent être activés selon les besoins. Cette séparation évite de rendre toute l'application dépendante de services secondaires.

#### outillage de développement et de déploiement

L'environnement de développement a été conçu pour être reproductible. La dépendance locale attendue est **Docker**. Les dépendances Node.js sont installées avec **pnpm** à l'intérieur des conteneurs afin d'éviter les écarts entre machines de développement.

Les outils principaux sont :

- **Git / GitHub** pour le versionnement et la traçabilité des commits ;
- **Docker Compose** pour le lancement local des services ;
- **Makefile** pour standardiser les commandes de validation, build, test et démarrage ;
- **pnpm** comme gestionnaire de paquets dans Docker ;
- **ESLint / Prettier** pour la qualité et l'homogénéité du code ;
- **SonarQube / SonarCloud** pour l'analyse de qualité et de sécurité ;
- **scripts shell** pour les smoke tests, la validation des secrets et les tests de phases ;
- **documentation Markdown** pour conserver les décisions techniques et fonctionnelles.

Cette approche permet à un membre de l'équipe de récupérer le projet, lancer les conteneurs et exécuter les vérifications sans dépendre d'une installation locale spécifique de Node.js ou npm.

#### stratégie de sécurisation

La stratégie de sécurité repose sur un principe : le client ne décide jamais seul de ses droits. L'interface et le SDK expriment une demande, mais les décisions de permission sont prises côté serveur.

Les mesures principales sont :

- authentification par JWT et sessions renouvelables ;
- gateway publique unique, les microservices restant privés ;
- validation des entrées côté API ;
- rate limiting sur les routes sensibles ;
- séparation des données par utilisateur, projet ou tenant ;
- contrôle d'accès RBAC et ABAC ;
- journalisation des actions sensibles ;
- stockage des secrets hors du code source ;
- chiffrement ou hachage des informations sensibles ;
- accès publics limités à la lecture seule ;
- révocation possible des liens publics et clés d'adapters ;
- prise en compte des exigences RGPD : export, suppression, portabilité et minimisation des données.

L'ABAC est particulièrement important pour Prismatica, car l'application doit permettre des règles fines : un utilisateur peut avoir le droit de modifier une ressource dans un projet, mais seulement si elle appartient à son équipe, si elle n'est pas publiée, ou si son rôle contient un attribut spécifique. Cette logique reste côté back-end pour éviter toute falsification depuis le navigateur.

### Public cible et profils utilisateurs

#### définition du public cible

L'application **Prismatica** s'adresse aux organisations qui ont besoin de transformer des données dispersées en interfaces exploitables, sans engager un développement spécifique à chaque changement métier. Le public cible principal est constitué d'équipes professionnelles qui utilisent déjà des données au quotidien mais qui manquent d'un outil unifié pour les structurer, les visualiser, les partager et les maintenir.

Les entreprises concernées peuvent être des TPE, PME, associations, équipes internes de grands groupes ou agences qui accompagnent plusieurs clients. Les secteurs les plus pertinents sont ceux où les données évoluent régulièrement et doivent être comprises rapidement : logistique, opérations terrain, marketing, restauration, gestion commerciale, ressources humaines, suivi de production, support client, gestion de projets, inventaire ou reporting.

La cible principale n'est pas uniquement le développeur. Prismatica vise surtout les **utilisateurs métier** : responsables d'équipe, coordinateurs, analystes, administrateurs fonctionnels, collaborateurs opérationnels et décideurs. Ces profils connaissent leurs données et leurs processus, mais n'ont pas toujours les compétences ou le temps pour écrire du SQL, développer une API ou maintenir une interface sur mesure.

Prismatica leur donne une autonomie encadrée : ils peuvent créer des espaces de données, composer des dashboards, modifier des vues et former leurs collègues, tout en restant dans un cadre sécurisé par les permissions, la traçabilité et les règles ABAC.

Les besoins principaux du public cible sont :

- remplacer des tableurs isolés par une base structurée ;
- créer rapidement une interface de consultation et de modification des données ;
- visualiser les indicateurs importants sans outil de BI complexe ;
- publier un dashboard officiel pour une équipe ou un client ;
- intégrer une vue ou un widget dans une page web existante ;
- limiter l'accès aux données selon le rôle, l'équipe, le projet, le contexte ou la propriété de la ressource ;
- réduire la dépendance aux développeurs pour les évolutions courantes ;
- conserver une architecture robuste pour les intégrations plus techniques.

#### détails des profils utilisateurs

Les profils utilisateurs de Prismatica sont organisés selon leur niveau d'autonomie, leur responsabilité sur les données et leur périmètre d'accès. Le système de permissions doit permettre de personnaliser ces profils finement grâce à une approche ABAC : l'accès ne dépend pas seulement d'un rôle global, mais aussi d'attributs comme le projet, l'équipe, le propriétaire de la donnée, le type de ressource, l'environnement ou l'action demandée.

| Profil                                  | Objectif principal                                           | Besoins fonctionnels                                                                                | Droits typiques                                                                   |
| --------------------------------------- | ------------------------------------------------------------ | --------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------- |
| Visiteur non authentifié                | Consulter une ressource publique ou contacter l'organisation | Voir un dashboard public, remplir un formulaire, lire une vue intégrée                              | Lecture publique limitée, aucune modification                                     |
| Utilisateur métier                      | Gérer ses propres projets de données                         | Créer des collections, importer des données, créer des vues, composer des dashboards                | CRUD sur ses projets, partage contrôlé, gestion de ses adapters                   |
| Collaborateur opérationnel              | Utiliser l'interface au quotidien                            | Consulter les données utiles, mettre à jour des statuts, filtrer, commenter ou compléter des lignes | Lecture/écriture limitée selon le projet, l'équipe ou les lignes autorisées       |
| Manager ou responsable d'équipe         | Piloter une activité et former les collègues                 | Créer des dashboards, suivre des KPI, organiser les vues, partager les espaces de travail           | Gestion des vues et dashboards d'équipe, invitation et formation des utilisateurs |
| Analyste / data-oriented user           | Exploiter les données pour produire des indicateurs          | Construire des graphiques, agrégations, exports, comparaisons, rapports                             | Lecture étendue, création de vues analytiques, exports contrôlés                  |
| Intégrateur / webmaster / product owner | Relier Prismatica à un site ou une application               | Générer un embed, configurer un endpoint, intégrer un formulaire ou un widget                       | Gestion des adapters, restrictions de domaines, clés API limitées                 |
| Employé support plateforme              | Accompagner les utilisateurs et surveiller la plateforme     | Consulter l'état des projets, diagnostiquer les adapters, modérer un dashboard public               | Lecture transverse encadrée, actions de support tracées                           |
| Administrateur plateforme               | Garantir la sécurité et la gouvernance globale               | Gérer les comptes, rôles, politiques, limites, configuration et conformité                          | Administration complète, actions sensibles auditées                               |

Cette répartition permet d'adapter Prismatica à plusieurs contextes. Une petite entreprise peut utiliser seulement quelques profils simples, tandis qu'une organisation plus structurée peut définir des règles avancées : par exemple, un manager peut modifier les dashboards de son équipe mais pas ceux d'un autre service ; un collaborateur peut modifier uniquement les lignes dont il est responsable ; un client externe peut consulter un dashboard public sans accéder aux données sources.

```mermaid
mindmap
  root((Public cible))
    organisations((Organisations))
      tpe((TPE / PME))
      agences((Agences et cabinets))
      grands_comptes((Equipes internes de grands groupes))
    secteurs((Secteurs d'activité))
      logistique((Logistique et opérations))
      marketing((Marketing et reporting))
      restauration((Restauration et réservation))
      services((Services et support client))
      industrie((Production et inventaire))
    utilisateurs((Utilisateurs finaux))
      metier((Utilisateurs métier))
      managers((Managers et superviseurs))
      analystes((Analystes data))
      integrateurs((Intégrateurs web))
      admins((Administrateurs plateforme))
```

#### Scénarios d'utilisation

Les scénarios suivants illustrent l'usage attendu de Prismatica dans un contexte professionnel. Ils montrent que l'application peut servir à la fois d'outil interne de gestion, d'interface de dashboarding et de couche de publication vers l'extérieur.

```mermaid
flowchart TB
  Start([Besoin métier<br/>Structurer, visualiser et partager des données])
  Core{{Prismatica<br/>Plateforme de données polymorphe}}

  Start --> Core

  subgraph P1[Utilisateur métier]
    direction TB
    U1[Créer un projet]
    U2[Définir des collections<br/>et champs typés]
    U3[Importer CSV / JSON]
    U4[Modifier les données<br/>dans une vue tableau]
    U5[Construire une interface<br/>de travail]
    U1 --> U2 --> U3 --> U4 --> U5
  end

  subgraph P2[Manager / responsable d'équipe]
    direction TB
    M1[Composer un dashboard]
    M2[Ajouter KPI et graphiques]
    M3[Partager une vue officielle]
    M4[Former les collègues]
    M5[Ajuster les permissions<br/>par équipe]
    M1 --> M2 --> M3 --> M4 --> M5
  end

  subgraph P3[Intégrateur web]
    direction TB
    I1[Générer un widget]
    I2[Définir les domaines<br/>autorisés]
    I3[Intégrer dans une page web]
    I4[Tester le rendu public<br/>en lecture seule]
    I5[Révoquer l'accès<br/>si nécessaire]
    I1 --> I2 --> I3 --> I4 --> I5
  end

  subgraph P4[Administrateur plateforme]
    direction TB
    A1[Définir rôles<br/>et politiques ABAC]
    A2[Contrôler les accès<br/>sensibles]
    A3[Surveiller adapters<br/>et logs]
    A4[Gérer exports et<br/>suppressions RGPD]
    A5[Auditer les actions<br/>critiques]
    A1 --> A2 --> A3 --> A4 --> A5
  end

  Core --> P1
  Core --> P2
  Core --> P3
  Core --> P4

  P1 --> Result([Données structurées<br/>et exploitables])
  P2 --> Result
  P3 --> Result
  P4 --> Result
```

Exemples concrets d'utilisation :

- une équipe marketing crée un dashboard officiel de suivi de campagne et l'intègre dans son intranet ;
- un restaurant publie un calendrier de disponibilité en lecture seule sur son site ;
- une équipe logistique suit ses interventions dans une vue kanban et un tableau de bord de performance ;
- un responsable commercial importe un fichier client, crée des indicateurs et partage une vue filtrée à son équipe ;
- un administrateur définit des règles ABAC pour que chaque collaborateur voie uniquement les données de son périmètre.

### Fonctionnalités attendues

#### clients

Les utilisateurs authentifiés doivent pouvoir :

- créer et gérer des projets ;
- créer des collections représentant des tables ou ensembles de données ;
- définir des champs typés : texte, nombre, date, booléen, sélection, relation, fichier ou champ calculé ;
- importer et exporter des données au format CSV ou JSON ;
- créer des vues polymorphes : tableau, graphique, KPI, calendrier, kanban ;
- composer des dashboards par glisser-déposer ;
- partager un dashboard en lecture seule ;
- intégrer une vue dans une page web via un widget sécurisé ;
- configurer des adapters d'entrée ou de sortie ;
- gérer leurs sessions et demander l'export ou la suppression de leurs données.

#### administrateurs

Les administrateurs doivent pouvoir :

- gérer les comptes utilisateurs et employés ;
- définir les rôles, groupes, attributs et politiques d'accès ;
- configurer les règles ABAC selon le projet, l'équipe, la ressource ou l'action ;
- consulter les métriques d'usage de la plateforme ;
- superviser les adapters, endpoints publics, webhooks et erreurs ;
- désactiver ou révoquer un accès public ;
- gérer les paramètres globaux : limites, formats autorisés, modèles d'email ;
- réaliser les actions RGPD : export, suppression, anonymisation ou audit.

#### users non authentifiés

Les visiteurs non authentifiés peuvent :

- consulter un dashboard public en lecture seule ;
- visualiser un widget intégré dans un site externe ;
- remplir un formulaire public généré depuis une collection ;
- utiliser la page de contact ;
- accéder uniquement aux ressources explicitement publiées.

Aucune modification de schéma, de donnée ou de permission ne doit être possible depuis un accès public.

#### MVP

Le MVP se concentre sur les fonctionnalités qui démontrent la valeur principale de Prismatica : transformer rapidement une donnée en interface exploitable.

Périmètre MVP :

- authentification et gestion de session ;
- création d'un projet ;
- création de collections et de champs ;
- import simple de données ;
- vue tableau filtrable et éditable ;
- au moins deux vues de visualisation : graphique et KPI ;
- création d'un dashboard ;
- partage en lecture seule ;
- permissions de base complétées par une structure compatible ABAC ;
- traçabilité des actions sensibles ;
- documentation d'installation Docker et pnpm.

#### perspective d'évolution

Les évolutions prévues concernent l'industrialisation de la plateforme et l'enrichissement de l'expérience utilisateur :

- éditeur de schéma visuel avec diagramme relationnel ;
- vues avancées : calendrier, kanban, carte, graphiques multi-séries ;
- génération d'endpoints REST contrôlés ;
- webhooks et imports planifiés ;
- bibliothèque de templates métiers ;
- système complet d'embed avec thème, langue et restrictions de domaines ;
- analytics avancées via plan de données dédié ;
- collaboration temps réel ;
- versioning des schémas et rollback ;
- marketplace d'adapters ;
- assistant de configuration pour guider les utilisateurs non techniques.

### Contraintes et risques

Le projet présente plusieurs contraintes liées à son ambition fonctionnelle et technique.

| Contrainte / risque                            | Impact possible                                        | Réponse prévue                                                      |
| ---------------------------------------------- | ------------------------------------------------------ | ------------------------------------------------------------------- |
| Largeur fonctionnelle du produit               | Risque de dispersion et de MVP trop vaste              | Priorisation autour du triptyque collections, vues, dashboards      |
| Données dynamiques créées par les utilisateurs | Complexité de modélisation et de validation            | Schéma contrôlé, types limités, migrations encadrées                |
| Permissions personnalisables                   | Risque de faille d'accès si la logique est côté client | Permissions serveur, ABAC, audit et tests d'accès                   |
| Dashboards publics et embeds                   | Risque d'exposition involontaire de données            | Lecture seule, tokens opaques, révocation, restrictions de domaines |
| Volumétrie des données                         | Risque de lenteur sur les vues et graphiques           | Pagination, agrégations serveur, cache et limites par plan          |
| Multiplication des services Docker             | Complexité de maintenance                              | Profils Compose par criticité et documentation d'exploitation       |
| Hétérogénéité SQL/NoSQL                        | Risque d'abstraction trop générale                     | Adapters spécialisés et vocabulaire API normalisé côté produit      |
| Conformité RGPD                                | Risque juridique et fonctionnel                        | Export, suppression, traçabilité et minimisation des données        |

La principale limite du projet concerne le temps disponible. Prismatica couvre un périmètre vaste : base de données visuelle, interface de type CMS métier, dashboards, adapters, embeds, permissions et infrastructure BaaS. Le MVP doit donc rester concentré sur les fonctionnalités qui prouvent la valeur du produit sans chercher à finaliser toutes les évolutions avancées.

### les livrables

Les livrables attendus pour le projet sont les suivants :

- dépôt GitHub contenant le code source, l'infrastructure et la documentation ;
- documentation d'installation et de lancement avec Docker Compose ;
- dossier projet décrivant le contexte, le besoin, la cible, l'architecture et les choix techniques ;
- documentation back-end de la plateforme mini-BaaS ;
- scripts de validation et de smoke tests ;
- configuration des services principaux : gateway, base de données, authentification, API, observabilité ;
- maquettes ou captures des interfaces principales ;
- jeu de données de test ou scripts de seed ;
- description des profils utilisateurs et des scénarios d'utilisation ;
- éléments de sécurité : authentification, permissions, séparation des accès, gestion des secrets ;
- procédure de déploiement ou d'exécution locale reproductible.

Ces livrables doivent permettre à un évaluateur, un développeur ou un membre d'équipe de comprendre le produit, de lancer l'environnement, de vérifier les choix techniques et d'identifier clairement les fonctionnalités réalisées ou prévues.

### Environnement humain et technique

#### Environnements humain et méthodologie

j'ai travaillé au sein d'une équipe de développement fonctionnant sous la méthodologie **Agile (Scrumban)**. Ce cadre a permis des cycles de développement itératifs et une collaboration étroite entre les membres de l'équipe, favorisant ainsi une adaptation rapide aux changements et une livraison continue de valeur. Nous avons utilisé des outils de gestion de projet tels que **Jira** pour suivre les tâches, les sprints et les progrès du projet, assurant une transparence totale et une communication efficace au sein de l'équipe.

les différents rôles au sein de l'équipe comprenaient un Product Owner, un Tech Lead, des développeurs front-end et back-end, ainsi que des spécialistes en sécurité. Chaque membre de l'équipe avait des responsabilités spécifiques, contribuant à la réussite globale du projet.

| Membre   | Rôle                                                    | spécialité             | Responsabilités observées / déduites                                                                                                                                    |
| :------- | ------------------------------------------------------- | ---------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| dlesieur | Product Owner / Tech Lead / Product manager / developer | project chef           | Conception de l'architecture, intégration Docker, orchestration des services, sécurité, écriture des services NestJS, outillage d'exploitation, documentation technique |
| daniel   | Product Owner / Developeur                              | assistant project chef | Conception et développement des interfaces utilisateur, intégration avec le back-end, optimisation de l'expérience utilisateur                                          |
| sergio   | Tech Lead / Développeur                                 | frontend               | Conception et développement de l'API, gestion de la base de données, implémentation de la logique métier, sécurité du back-end                                          |
| roxanne  | Tech Lead                                               | security               | Analyse des risques de sécurité, mise en place de mesures de protection, audits de sécurité, conformité RGPD                                                            |
| vadim    | Product Manager / Developer                             | scrum manager          | Analyse des risques de sécurité, mise en place de mesures de protection, audits de sécurité, conformité RGPD                                                            |

J'étais donc au centre du processus, responsable de la chaîne complète de développement, de la donnée(BDD) à l'interface (front-end). L'organization de mon équipe tourné autour des principes de scrum, avec des réunions quotidiennes pour synchroniser les progrès, des revues de sprint pour évaluer les livrables et des rétrospectives pour identifier les axes d'amélioration. Cette approche a permis une collaboration efficace et une adaptation rapide aux changements de priorités ou de besoins du projet.

##### Rituels

Scrumban combine les éléments de Scrum et de Kanban pour offrir une flexibilité maximale dans la gestion des projets. Nous avons d'une part
scrum avec lequel des rituels mis en place pour assurer une collaboration efficace et une livraison continue de valeur:

- **Daily Stand-up**: une réunion quotidienne de 15 minutes pour synchroniser les progrès, identifier les obstacles et planifier les tâches pour la journée.
- **Sprint Planning**: une réunion au début de chaque sprint pour planifier les tâches à
- **DoD** (Definition of Done): une liste de critères que chaque tâche doit remplir pour être considérée comme terminée, assurant ainsi la qualité et la cohérence des livrables.
- **Sprint Review**: une réunion à la fin de chaque sprint pour présenter les livrables aux parties prenantes, recueillir des feedbacks et ajuster les priorités pour les prochains sprints.
- **Sprint Retrospective**: une réunion pour réfléchir sur le sprint écoulé, identifier ce qui a bien fonctionné, ce qui peut être amélioré et définir des actions concrètes pour améliorer les processus de travail.

mais aussi kanban avec lequel nous avons mis en place un tableau de tâches visuel pour suivre l'avancement du projet, avec des colonnes représentant les différentes étapes du processus de développement (To Do, In Progress, Done). Cela a permis une gestion flexible des tâches et une adaptation rapide aux changements de priorités.

> Contraintes:
> comme le projet avait une portée relativement large, il était essentiel de maintenir une communication claire et efficace au sein de l'équipe pour éviter les > malentendus et assurer une coordination fluide. De plus, la gestion du temps était un défi constant, nécessitant une planification rigoureuse et une capacité à s'adapter rapidement aux changements de priorités ou de besoins du projet. À cet effet, nous avons mis en place une fois par semaine une réunion pour travailler l'écoute active et autre modalité de communication pour améliorer la collaboration au sein de l'équipe.
> :warning: utiliser kanban pour l'intégralité du projet était une option trop lourde due à la largeur et la complexité du projet, et parce que nous étions habitué de faire des projets en solitaires beaucoup plus petits, nous avons opté pour utiliser le kanban seulement quand le container à créer demandé un très haut niveau de rigueur et de suivi, comme c'était le cas pour la partie développement du front-end avec `osionos` un container qui créer littéralement l'interface applicative de la solution. [pour en savoir plus](#ref-osionos)

##### Post de développement

- système d'exploitation: j'ai opéré sur un environnement Linux (Ubuntu) pour le développement, offrant une compatibilité optimale avec les outils et technologies utilisés dans le projet.
- IDE: Mon environnement de développement principal était **Visual Studio Code**, complété par des extensions pour l'investigation de code, la gestion de Git et le développement en React et Node.js.
- Environnement: les dépendances applicatives sont gérées avec pnpm dans Docker afin d'éviter les écarts entre postes de développement; la dépendance locale attendue est Docker.

##### pile applicative (conforme aux choix architecturaux)

- Front-end: Développé avec la librairie `React`. La stylisation a été assurée par `SCSS` (Sass) pour une meilleur modularité des feuillees de style et pour faciliter le _responsive design_
- Back-end: Construit avec `Node.js` et le framework `vite` pour une configuration rapide et une expérience de développement optimisée. J'ai utilisé `Express` pour la gestion des routes et des middlewares, et `MongoDB` et `PostgreSQL` pour la gestion des données, en fonction des besoins spécifiques de chaque fonctionnalité.
- base de données: j'ai utilisé `MongoDB` pour stocker les utilisateurs, les clients et les interventions. Les interactions se font via l'ORM `mongoose` qui garantit une gestion efficace des données et une intégration fluide avec le back-end.

##### gestion du code et contrôle de qualité

- J'ai utilisé l'outil Git avec un dépôt hébergé sur GitHub, ce qui a permis d'assurer un suivi précis de toutes les modifications apportées au projet.
- Nous avons adopté un workflow standard (gitflow) pour la production, incluant une branch principale `main` pour le code stable en production, incluant une branche de développement (develop) pour l'intégration de nouvelles fonctionnalités (feat/, bugfix/, hotfix/, migrate/, etc.) pour le développement et des branches de release pour la préparation des déploiements en production.
- J'ai systématiquement veillé à la rédaction des commits clairs et descriptifs, en utilisant les `hook` de pré-commit pour assurer la qualité du code avant chaque commit, notamment en exécutant des tests unitaires et en vérifiant le respect des normes de codage. Cela m'a assuré d'accroitre la lisibilité de l'historique des modifications et de faciliter la collaboration avec les autres membres de l'équipe. (cela fonctionne avec un regexp)
- dans tous les containers nous sommes stricts. Nous avons mis en place des règles de linting et de formatage pour garantir la cohérence du code, ainsi que des tests unitaires pour assurer la fiabilité et la maintenabilité du code à long terme. Nous avons également utilisé des outils d'intégration continue pour automatiser les tests et les vérifications de qualité à chaque commit, assurant ainsi une livraison continue de code de haute qualité. Des outils comme `ESLint` pour le linting et `Prettier` pour le formatage ont été intégrés dans notre workflow de développement, garantissant que le code respecte les normes de style et de qualité définies par l'équipe. mais aussi des outils comme `sonarcloud` pour l'analyse de la qualité du code et la détection de vulnérabilités potentielles, assurant ainsi une sécurité renforcée et une maintenabilité à long terme du projet.
- les fonctionnalités cirtique (connexion sécurisée, mise à jour du statut d'intervention validation du rapport) ont été vérifiées par des scénarios de test manuels détaillés, afin de garantir la stabilité fonctionnelle de l'application avant son déploiement en recette.

##### Environnements

Pour garantir la qualité et la progresssion du développement, l'application a été développée et testée dans différents environnements:

- \*_Environnement de développement_: utilisé pour le développement quotidien, avec des outils de débogage et de test intégrés pour faciliter le processus de développement.
- **Environnement de test**:
  - Version intermédiaire déployée sur un serveur de test dédié, utilisant des données anonymisées.
  - Cet environnement a servi à la validation des fonctionnalités avec le Lead Technique et le Client avant tout déploiement en production.
  - C'est le lieu où la revue de Sprint a été effectuée

##### Organisation du travail et rituels de projets

Pour garantir la sécurité des accès et la confidentialité des informations critiques dans chaque environnement, j'ai appliqué la stratégie suivante:

- **Gestion des secrets**: J'ai utilisé des outils de gestion des secrets tels que `Vault` pour stocker et gérer les informations sensibles, assurant ainsi une protection robuste contre les accès non autorisés.
- **Contrôle d'accès**: J'ai mis en place des politiques de contrôle d'accès strictes, en utilisant des rôles et des permissions pour limiter l'accès aux données sensibles uniquement aux utilisateurs autorisés, garantissant ainsi la confidentialité et la sécurité des informations critiques.
- Chaque environnement (développement local, recette, production) possède sa propre version du fichier, adaptée à ses besoins de configuration spécifiques.
- le back-end Node.js accède à ses configurations uniquement via les variables d'environnement, assurant la séparation du code et des secrets.

##### Configuration et gestion des secreets

Protection maximal via `bcrypt` pour le hachage des mots de passe, `JWT` pour la gestion des sessions et des tokens d'authentification, et `Vault` pour la gestion centralisée des secrets, assurant ainsi une sécurité renforcée pour les données sensibles de l'application.

Mise en place d'une traçabilité des actions sensibles (connexions, modifications de statut) pour les besoins d'audit

Conformité aux exigences RGAA (sémantique, constrastes, navigation clavier) pour une utilisation incusive sur les terminaux mobiles.

Optimisation du temps de réponse par la pagination de l'API et l'ajout d'index SQL sur les tables fréquemment consultées, assurant ainsi une expérience utilisateur rapide et fluide même avec de grandes quantités de données.

Validation systématique par des scénarios de recette manuels sur les fonctionnalités clés (front et back-end) pour garantir la stabilité fonctionnelle du système.

##### Outillage et données de test

- Jeu de données: Établissement d'un jeu de d'essai complet et cohérent pour tester les différentes fonctionnalités de l'application, en utilisant des données anonymisées pour garantir la confidentialité et la sécurité des informations sensibles.
- Sécurité et initialisation de l'environnement de test: script SQL versionnés pour l'installation rapide et sécurisée de l'environnement de test.
- Transferabilité: Capacité d'extension des données (formats CSV/JSON) pour faciliter les audits et les migrations entre environnements.

### Objectifs de qualité

```mermaid
graph TD
    A[Code source] --> B[intégration et test]
    B--> C[Environnement de recette]
    C --> D[déploiement en production]
    D --> E[Supervision & sauvegardes]
```

## CHAPITRE 3. Les réalisations personnelles, front-end (React / SCSS)

## Maquette de l'application et schémas

### Conception "desktop first with mobile companion" et wireframes

### Charte graphique

### typographie

### schéa d'enchainement des maquettes

### Captures d'écran des interfaces utilisateur

### Extraits de code, interfaces utilisateur statiques (React / SCSS)

#### Organisation minimal du projet front

#### Extrait de code, page de connexion (statique et accessible)

### Extrait de code, partie dynamique(React/typecript)

#### Authentification: le formulaire de connexion dynamique

#### récupération des données: la liste des interventions

#### action métier critique: mise à jour du statut d'intervention

## CHAPITRE 4. Les réalisations personnelles, back-end (Node.js / Express / MongoDB / POSTGRESQL)

### Architecture de l'API et modèle de données

#### a. Comprendre le rôle du BaaS dans Prismatica

Le back-end de Prismatica n'a pas été conçu comme une simple API métier contenant quelques routes spécifiques. Il a été pensé comme une plateforme **BaaS**, c'est-à-dire un **Backend as a Service** auto-hébergé. Le principe est de fournir à l'application des briques back-end déjà prêtes : authentification, gateway, base relationnelle, base documentaire, permissions, stockage de fichiers, temps réel, logs, métriques, services d'arrière-plan et génération de schémas.

Cette approche correspond bien au besoin de Prismatica. L'application doit permettre à des équipes métier de créer des collections, des vues, des dashboards et des interfaces sans redévelopper un serveur à chaque nouveau cas d'usage. Le BaaS sert donc de socle technique commun : il reçoit les demandes du front-end, vérifie l'identité et les droits, choisit le bon service interne, interroge la bonne base de données et renvoie une réponse normalisée.

Dans cette architecture, le client ne pilote jamais directement la sécurité ni la base de données. Le navigateur, l'interface React ou le SDK JavaScript expriment une intention : lire une collection, créer une ressource, publier un dashboard, générer une URL de fichier ou lancer une requête. Le back-end reste l'autorité : il valide les entrées, applique les permissions et exécute l'action dans le service approprié.

```mermaid
flowchart TB
  subgraph Clients[Clients de Prismatica]
    Web[Interface React]
    SDK[SDK JavaScript]
    Embed[Widget intégré]
    Backend[Backend partenaire]
  end

  subgraph Edge[Entrée publique contrôlée]
    WAF[WAF Nginx<br/>ModSecurity + OWASP CRS]
    Kong[Kong Gateway<br/>routage, JWT, API key, CORS]
  end

  subgraph BaaS[mini-BaaS privé]
    Auth[GoTrue<br/>identité et JWT]
    Rest[PostgREST<br/>API SQL générique]
    Query[Query Router<br/>API SQL / NoSQL normalisée]
    Storage[Storage Router<br/>URLs présignées]
    Realtime[Realtime<br/>WebSocket / CDC]
    Services[Services NestJS<br/>métier plateforme]
  end

  subgraph Data[Plans de données]
    PG[(PostgreSQL)]
    Mongo[(MongoDB)]
    Redis[(Redis)]
    MinIO[(MinIO / S3)]
  end

  Web --> SDK
  Embed --> SDK
  Backend --> SDK
  SDK --> WAF --> Kong
  Kong --> Auth
  Kong --> Rest
  Kong --> Query
  Kong --> Storage
  Kong --> Realtime
  Kong --> Services
  Auth --> PG
  Rest --> PG
  Query --> PG
  Query --> Mongo
  Query --> Redis
  Storage --> MinIO
  Realtime --> PG
  Services --> PG
  Services --> Mongo
```

Le diagramme montre que le BaaS agit comme une couche d'abstraction. Le front-end ne connaît pas l'emplacement réel des bases ni les détails des services internes. Il communique avec une API publique stable, puis la plateforme se charge de l'orchestration.

#### b. Architecture générale de l'API

L'architecture est organisée en plusieurs plans. Cette séparation évite de traiter tous les conteneurs comme s'ils étaient aussi critiques. Le cœur BaaS contient le chemin de requête indispensable : WAF, Kong, PostgreSQL, GoTrue, PostgREST, Realtime et Redis. Les services plus spécialisés sont activés selon les besoins avec des profils Docker Compose.

| Plan | Rôle | Services principaux | Criticité |
| ---- | ---- | ------------------- | --------- |
| Entrée publique | Filtrer et router les requêtes venant de l'extérieur | WAF, Kong Gateway | Très élevée |
| Cœur BaaS | Authentification, REST SQL, temps réel et cache | GoTrue, PostgREST, PostgreSQL, Realtime, Redis | Très élevée |
| Adapter plane | API de données normalisée SQL / NoSQL | query-router, adapter-registry, permission-engine | Élevée si l'API multi-base est utilisée |
| Control plane | Administration, secrets, schémas et métadonnées | Vault, schema-service, pg-meta, Studio, Supavisor | Moyenne, surtout admin |
| Data plane | Stockages secondaires et fichiers | MongoDB, MinIO, storage-router | Variable selon les fonctionnalités |
| Analytics | Requêtes analytiques et fédération | Trino, analytics-service | Non critique pour le CRUD |
| Background | Traitements asynchrones | email-service, newsletter-service, gdpr-service, ai-service, session-service | Non bloquant |
| Observabilité | Surveillance, logs et métriques | Prometheus, Grafana, Loki, Promtail, log-service | Forte en production |

```mermaid
flowchart LR
  subgraph Hot[Chemin critique]
    WAF[WAF] --> Kong[Kong]
    Kong --> Auth[GoTrue]
    Kong --> Rest[PostgREST]
    Kong --> RT[Realtime]
    Auth --> PG[(PostgreSQL)]
    Rest --> PG
    RT --> PG
    Kong --> Redis[(Redis)]
  end

  subgraph Adapter[Plan adapter]
    Kong -. /query/v1 .-> QR[query-router]
    QR --> PE[permission-engine]
    QR --> AR[adapter-registry]
    QR --> PG
    QR --> Mongo[(MongoDB)]
  end

  subgraph Control[Plan contrôle]
    Vault[Vault]
    Schema[schema-service]
    Meta[pg-meta / Studio]
  end

  subgraph Extra[Plans optionnels]
    MinIO[(MinIO)]
    Trino[Trino]
    Obs[Prometheus / Grafana / Loki]
    Bg[Emails / RGPD / IA / logs]
  end

  Schema --> AR
  Schema --> PG
  Storage[storage-router] --> MinIO
  Trino --> PG
  Trino --> Mongo
  QR -. métriques .-> Obs
  Kong -. métriques .-> Obs
```

Le choix important est que le CRUD relationnel de base peut rester disponible même si les services optionnels sont arrêtés. Par exemple, une panne du service analytics ou du service email ne doit pas empêcher la connexion d'un utilisateur ni la lecture d'une table via PostgREST.

#### c. Clients, SDK et passerelle API

Plusieurs types de clients peuvent utiliser Prismatica : l'interface React principale, un widget public intégré dans un site externe, un back-end partenaire ou un outil d'administration. Pour éviter que chaque client connaisse les routes internes, un SDK JavaScript sert de couche d'accès produit.

Le SDK expose des méthodes compréhensibles : se connecter, lire une collection, créer un document, générer une URL de stockage, envoyer un événement analytics ou récupérer l'état de la plateforme. En interne, le SDK ajoute les clés publiques, le JWT utilisateur, les timeouts, les retries et les erreurs normalisées.

La passerelle API `Kong` est le seul point d'entrée applicatif. Elle applique les contrôles transverses : CORS, API key, vérification JWT, rate limiting, limitation de taille des requêtes, corrélation par `X-Request-ID` et ajout d'en-têtes d'identité de confiance pour les services internes.

```mermaid
sequenceDiagram
  autonumber
  participant U as Utilisateur
  participant F as Front React / SDK
  participant W as WAF
  participant K as Kong Gateway
  participant S as Service privé
  participant D as Base de données

  U->>F: Action métier
  F->>W: Requête HTTPS + apikey + JWT
  W->>K: Requête filtrée
  K->>K: CORS, rate-limit, JWT, X-Request-ID
  K->>S: Route privée + X-User-Id
  S->>S: Validation DTO + permissions
  S->>D: Lecture / écriture contrôlée
  D-->>S: Résultat
  S-->>K: Réponse normalisée
  K-->>F: Réponse + X-Request-ID
  F-->>U: Affichage ou message d'erreur
```

Cette organisation simplifie le front-end. Le client n'a pas besoin de connaître l'adresse de MongoDB, de PostgreSQL, de MinIO ou des services NestJS. Il connaît seulement l'URL publique de la plateforme.

#### d. Maillage de services et communication interne

Le projet utilise un **maillage logique de services**. Il ne s'agit pas d'un service mesh Kubernetes complet comme Istio ou Linkerd, mais d'une organisation équivalente à l'échelle Docker Compose : chaque service est isolé dans son conteneur, possède un nom DNS privé, expose des endpoints de santé et communique avec les autres services par HTTP interne.

Les règles du maillage sont les suivantes :

- les services internes ne sont pas appelés directement depuis Internet ;
- la gateway est le point d'entrée unique ;
- les appels internes utilisent les noms de services Docker, par exemple `http://permission-engine:3050` ;
- les appels machine-to-machine sensibles utilisent un en-tête `X-Service-Token` ;
- chaque requête garde un `X-Request-ID` pour relier les logs ;
- les services exposent des endpoints de santé `health/live` et `health/ready` ;
- les erreurs sont normalisées pour faciliter le diagnostic.

```mermaid
flowchart TB
  subgraph Mesh[Maillage privé Docker]
    QR[query-router]
    PE[permission-engine]
    AR[adapter-registry]
    SS[schema-service]
    LS[log-service]
    SR[storage-router]
  end

  K[Kong Gateway] -->|HTTP privé| QR
  K -->|HTTP privé| SR
  K -->|HTTP privé| SS

  QR -->|check permission| PE
  QR -->|X-Service-Token<br/>connexion chiffrée| AR
  QR -->|événements async| LS
  SS -->|métadonnées DB| AR

  QR --> PG[(PostgreSQL)]
  QR --> Mongo[(MongoDB)]
  SR --> MinIO[(MinIO)]

  classDef private fill:#eef6ff,stroke:#3478c6,stroke-width:1px;
  class QR,PE,AR,SS,LS,SR private;
```

Ce maillage apporte une meilleure séparation des responsabilités. Le service de permissions ne gère pas les connexions aux bases. Le registre d'adapters ne décide pas si une requête est autorisée. Le query-router orchestre, mais délègue les décisions spécialisées aux services dédiés.

#### e. Services autonomes et conteneurisation

Chaque service applicatif personnalisé est développé en Node.js avec TypeScript et NestJS. Le nom du chapitre mentionne Express, car Express reste l'écosystème HTTP classique de Node.js ; dans le projet, NestJS fournit une architecture plus structurée au-dessus du runtime Node : modules, contrôleurs, services, injection de dépendances, DTOs et guards.

Les services sont construits avec un Dockerfile commun. Le même Dockerfile peut compiler plusieurs applications en utilisant un argument de build. Cela évite de maintenir un Dockerfile différent pour chaque microservice.

| Service | Responsabilité principale | Données / dépendances |
| ------- | ------------------------- | --------------------- |
| query-router | Exécuter une intention de lecture ou mutation vers PostgreSQL ou MongoDB | adapter-registry, permission-engine, Redis |
| adapter-registry | Enregistrer les bases des tenants et chiffrer les chaînes de connexion | PostgreSQL, AES-256-GCM, clé Vault |
| permission-engine | Vérifier les droits RBAC / ABAC côté serveur | PostgreSQL, fonction `has_permission()` |
| schema-service | Créer des tables ou collections depuis une spécification | PostgreSQL, MongoDB, adapter-registry |
| mongo-api | Fournir une API documentaire propriétaire | MongoDB |
| storage-router | Générer des URLs présignées pour fichiers | MinIO / S3 |
| analytics-service | Stocker et lire les événements analytiques | MongoDB |
| email-service | Envoyer des emails transactionnels | SMTP |
| gdpr-service | Gérer consentement, export et suppression | PostgreSQL, webhooks |
| log-service | Recevoir et exposer des logs applicatifs | Mémoire / observabilité |
| session-service | Gérer des sessions applicatives complémentaires | PostgreSQL |
| ai-service | Fournir un client LLM compatible OpenAI | API LLM, MongoDB |

```mermaid
flowchart TB
  subgraph Build[Build applicatif]
    DF[Dockerfile Node 20 + pnpm]
    Arg[ARG APP]
  end

  subgraph Apps[Applications NestJS]
    A1[adapter-registry]
    A2[query-router]
    A3[permission-engine]
    A4[schema-service]
    A5[storage-router]
    A6[services background]
  end

  DF --> Arg
  Arg --> A1
  Arg --> A2
  Arg --> A3
  Arg --> A4
  Arg --> A5
  Arg --> A6

  A1 --> H1[/health/live/]
  A2 --> H2[/health/live/]
  A3 --> H3[/health/live/]
  A4 --> H4[/health/live/]
```

Grâce aux conteneurs, chaque service possède son cycle de vie : démarrage, healthcheck, redémarrage, limites CPU/mémoire et dépendances. Cela rend le système plus facile à isoler, tester et faire évoluer.

#### f. Contrats API, validation et sécurité applicative

Le back-end repose sur des contrats explicites. Les entrées sont décrites par des DTOs, validées avant traitement, puis transformées en objets typés. Les contrôleurs reçoivent les requêtes HTTP, les services appliquent la logique, et les guards imposent l'authentification ou les rôles.

Les contrats importants sont :

| Contrat | Fonction | Exemple dans le projet |
| ------- | -------- | ---------------------- |
| DTO | Décrire et valider le corps des requêtes | requête de query, création de schéma, génération d'URL de stockage |
| Guards | Refuser les accès non authentifiés ou non autorisés | `AuthGuard`, `RolesGuard`, `ServiceTokenGuard` |
| En-têtes de confiance | Transmettre l'identité validée par la gateway | `X-User-Id`, `X-User-Email`, `X-User-Role` |
| Corrélation | Suivre une requête dans plusieurs services | `X-Request-ID` |
| Health checks | Vérifier l'état d'un conteneur | `health/live`, `health/ready` |
| Réponses normalisées | Garder un format prévisible côté client | interceptors et filtres d'exception |

```mermaid
flowchart LR
  Req[Requête HTTP] --> Guard[Guard auth / rôle]
  Guard --> DTO[Validation DTO]
  DTO --> Service[Service applicatif]
  Service --> Policy[Permission / règle métier]
  Policy --> Data[Accès données]
  Data --> Transform[Réponse normalisée]
  Transform --> Client[Client]

  Guard -. erreur .-> Error[Filtre d'exception]
  DTO -. erreur .-> Error
  Policy -. refus .-> Error
  Error --> Client
```

Cette structure limite les risques classiques : injection, requêtes mal formées, accès non authentifiés, contournement des droits ou erreurs non exploitables par le front-end.

#### g. Fournisseur d'identité et gestion des accès

L'identité est fournie par GoTrue. Ce service gère l'inscription, la connexion, les tokens JWT, les refresh tokens, le MFA et les fournisseurs OAuth possibles. Une fois connecté, l'utilisateur reçoit un JWT. Ce token est envoyé à la gateway à chaque requête protégée.

Kong vérifie le JWT et ajoute ensuite des en-têtes d'identité aux services internes. Les services n'ont donc pas à réinterpréter seuls le token à chaque appel. Ils lisent une identité déjà contrôlée par la gateway.

Pour les droits fins, le projet utilise un moteur de permissions séparé. Le `permission-engine` s'appuie sur des rôles, des policies et une fonction SQL de type ABAC. Cela permet d'exprimer des règles comme : un utilisateur peut lire une ressource uniquement si elle appartient à son tenant, à son équipe, ou si l'action demandée correspond à son rôle.

```mermaid
sequenceDiagram
  autonumber
  participant C as Client
  participant K as Kong
  participant G as GoTrue
  participant Q as query-router
  participant P as permission-engine
  participant DB as PostgreSQL

  C->>K: POST /auth/v1/token
  K->>G: Identifiants
  G->>DB: Vérification utilisateur
  G-->>C: JWT + refresh token

  C->>K: POST /query/v1 avec JWT
  K->>K: Vérification JWT
  K->>Q: X-User-Id + X-User-Role
  Q->>P: check(user, resource, action)
  P->>DB: has_permission(...)
  DB-->>P: true / false
  P-->>Q: autorisé ou refusé
```

Le point essentiel est que l'interface peut masquer ou afficher certains boutons selon les droits connus, mais elle ne décide jamais définitivement. La décision réelle est toujours contrôlée côté serveur.

#### h. Bases de données, stockage et contenu statique

Le BaaS utilise plusieurs formes de stockage, chacune avec un rôle précis.

| Stockage | Usage principal | Pourquoi ce choix |
| -------- | --------------- | ----------------- |
| PostgreSQL | Données relationnelles, auth, policies, registres, schémas | Fiabilité, SQL, transactions, RLS, contraintes |
| MongoDB | Données documentaires, analytics, collections flexibles | Souplesse de modèle, documents JSON, change streams |
| Redis | Cache, coalescing, futurs usages pub/sub ou queues | Rapidité, TTL, partage entre instances |
| MinIO | Fichiers, imports, exports, médias, pièces jointes | Compatible S3, auto-hébergeable |
| Trino | Requêtes analytiques et fédérées | Analyse multi-sources sans impacter le CRUD |

Le contenu statique est séparé de l'API. Les fichiers d'interface, les assets et les widgets publics peuvent être servis par un serveur web ou un CDN. Les fichiers métier, comme les exports CSV, images, documents ou pièces jointes, sont stockés dans MinIO. Le client n'accède pas directement aux credentials S3 : il demande au `storage-router` une URL présignée limitée dans le temps.

```mermaid
flowchart TB
  subgraph Static[Contenu statique]
    Assets[Assets front-end<br/>HTML / CSS / JS / images]
    Widget[Widget public intégré]
  end

  subgraph API[API BaaS]
    Kong[Kong]
    Storage[storage-router]
    Rest[PostgREST]
    Query[query-router]
  end

  subgraph Stores[Stockages]
    PG[(PostgreSQL)]
    Mongo[(MongoDB)]
    Redis[(Redis)]
    Obj[(MinIO / S3)]
  end

  Assets --> Kong
  Widget --> Kong
  Kong --> Rest --> PG
  Kong --> Query
  Query --> PG
  Query --> Mongo
  Query --> Redis
  Kong --> Storage --> Obj
```

Ce découpage évite de confondre les responsabilités : les assets statiques servent l'interface, l'API traite les données, et MinIO stocke les fichiers utilisateurs.

#### i. Fonctionnement du query-router

Le `query-router` est une partie centrale de l'API de données normalisée. Il permet d'envoyer une intention produit sans exposer directement les détails internes de PostgreSQL ou MongoDB. Par exemple, le SDK peut demander une action `read`, `create`, `update` ou `delete`. Le query-router transforme ensuite cette action en opération adaptée au moteur ciblé : `select` ou `insert` pour PostgreSQL, `find` ou `insertOne` pour MongoDB.

Le chemin est volontairement sécurisé :

1. le query-router récupère la connexion de la base dans l'`adapter-registry` ;
2. il vérifie les droits avec le `permission-engine` ;
3. il applique le cache de lecture si l'action est éligible ;
4. il exécute la requête dans le moteur PostgreSQL ou MongoDB ;
5. il invalide le cache en cas de mutation ;
6. il envoie des métriques et événements asynchrones.

```mermaid
flowchart TB
  Start([Requête /query/v1]) --> Conn[Lire adapter-registry<br/>connexion chiffrée]
  Conn --> Perm[permission-engine<br/>RBAC / ABAC]
  Perm --> Allowed{Autorisé ?}
  Allowed -- Non --> Deny[Refus contrôlé]
  Allowed -- Oui --> Read{Action lecture ?}

  Read -- Oui --> Cache{Cache L1 / Redis L2 ?}
  Cache -- Hit --> ReturnCache[Retour résultat cache]
  Cache -- Miss --> Coalesce[Coalescing anti-stampede]
  Coalesce --> Engine[Exécution moteur]

  Read -- Non --> Invalidate[Invalidation cache]
  Invalidate --> Engine

  Engine --> SQL[(PostgreSQL)]
  Engine --> NoSQL[(MongoDB)]
  SQL --> Result[Réponse normalisée]
  NoSQL --> Result
  Result --> Metrics[Métriques + événements]
```

Cette couche évite que le front-end contienne des règles spécifiques à chaque base. Le produit garde un vocabulaire commun, tandis que le back-end conserve la logique d'exécution et de sécurité.

#### j. Modèle de données conceptuel

Le modèle de données combine un socle système et des données métier dynamiques. Le socle système stocke les utilisateurs, rôles, policies, bases enregistrées et schémas. Les données métier peuvent ensuite vivre dans PostgreSQL ou MongoDB selon le type de projet.

```mermaid
erDiagram
  USER ||--o{ USER_ROLE : possede
  ROLE ||--o{ USER_ROLE : attribue
  ROLE ||--o{ RESOURCE_POLICY : autorise
  USER ||--o{ TENANT_DATABASE : enregistre
  TENANT_DATABASE ||--o{ SCHEMA_REGISTRY : contient
  SCHEMA_REGISTRY ||--o{ RESOURCE : decrit
  RESOURCE ||--o{ RECORD : stocke
  USER ||--o{ SESSION : ouvre
  USER ||--o{ AUDIT_LOG : produit

  USER {
    uuid id
    string email
    string role
  }
  ROLE {
    uuid id
    string name
  }
  RESOURCE_POLICY {
    uuid id
    string resource_type
    string resource_name
    string action
  }
  TENANT_DATABASE {
    uuid id
    uuid tenant_id
    string engine
    string name
    binary connection_enc
  }
  SCHEMA_REGISTRY {
    uuid id
    string engine
    string schema_name
  }
  RESOURCE {
    uuid id
    string type
    string name
  }
  RECORD {
    uuid id
    json data
  }
```

Ce schéma est conceptuel. Il ne représente pas une seule table unique contenant tout le métier, mais la logique générale de la plateforme : identité, droits, registres, schémas et ressources manipulées par Prismatica.

### Extraits de code, structure et sécurité de l'API

#### Choix techniques (contexte et logique)

La structure back-end est organisée en services NestJS indépendants. Chaque service contient ses contrôleurs, ses DTOs, ses services métier et ses modules. Une librairie commune fournit les éléments transverses : guards d'authentification, validation, filtres d'erreurs, interceptors de réponse et corrélation des requêtes.

Le choix NestJS apporte une architecture plus robuste qu'un serveur Express minimal :

- les contrôleurs restent concentrés sur l'entrée HTTP ;
- les services contiennent la logique métier ;
- les DTOs rendent les contrats explicites ;
- l'injection de dépendances facilite les tests et la séparation des responsabilités ;
- les guards rendent la sécurité réutilisable ;
- les interceptors standardisent les réponses.

#### Extrait: contrôle d'ownership et règle d'habilitation critique

La règle d'habilitation la plus importante est la suivante : un utilisateur ne peut pas accéder à une ressource uniquement parce qu'il connaît son identifiant. Les services vérifient son identité, son tenant, ses rôles et les policies applicables.

L'`adapter-registry` illustre ce principe. Les bases enregistrées appartiennent à un tenant. Les chaînes de connexion sont chiffrées avec AES-256-GCM. Lorsqu'une connexion est demandée, le service effectue une requête tenant-aware et ne renvoie la connexion déchiffrée que si la base appartient bien à l'utilisateur ou au tenant autorisé.

```mermaid
flowchart LR
  User[Utilisateur authentifié] --> Request[Demande connexion DB]
  Request --> Registry[adapter-registry]
  Registry --> RLS[Requête tenant-aware]
  RLS --> Match{tenant_id correspond ?}
  Match -- Non --> NotFound[404 / refus]
  Match -- Oui --> Decrypt[Déchiffrement AES-256-GCM]
  Decrypt --> Return[Connexion transmise au service interne]
```

Cette règle empêche un utilisateur d'exploiter un identifiant deviné pour atteindre une base qui ne lui appartient pas. Même si la route est appelée correctement, l'accès reste filtré côté serveur.

#### Extrait 2: mise à jour contrôlée et validation métier

Pour une mutation, le query-router ne se contente pas d'exécuter une requête. Il convertit l'action produit en action technique, vérifie les permissions, invalide le cache concerné, exécute la mutation puis enregistre les métriques. Cela permet de conserver une logique cohérente entre PostgreSQL et MongoDB.

| Étape | Objectif | Risque évité |
| ----- | -------- | ------------ |
| Validation de l'action | Accepter seulement `read`, `create`, `update`, `delete` | Opération inconnue ou dangereuse |
| Vérification ABAC | Confirmer le droit côté serveur | Escalade de privilèges côté client |
| Invalidation cache | Éviter de servir une ancienne valeur | Données périmées après mutation |
| Exécution moteur | Appliquer l'opération SQL ou NoSQL | Couplage direct du client à la DB |
| Métriques / événement | Observer le comportement | Débogage impossible en production |

#### d. Préparation du déploiement

Le déploiement est préparé autour de Docker Compose, des profils de services et de scripts de validation. La dépendance locale principale est Docker. Les dépendances Node.js sont installées avec pnpm dans les conteneurs afin de limiter les écarts entre postes de développement.

Les contrôles de production retenus sont :

- gateway unique en entrée ;
- services internes privés ;
- variables d'environnement et secrets séparés du code ;
- healthchecks Docker ;
- limites mémoire et CPU sur les services critiques ;
- scripts de smoke test ;
- métriques Prometheus ;
- logs centralisés avec Loki / Promtail ;
- dashboards Grafana ;
- séparation des plans de criticité.

### Pourquoi cette architecture plutôt qu'un monolithe ?

Une architecture monolithique aurait été plus simple au démarrage : un seul serveur, une seule base, un seul déploiement. Cependant, Prismatica doit fournir une plateforme générique, extensible, multi-service et sécurisée. Le choix BaaS modulaire devient plus pertinent, car les fonctionnalités n'ont pas toutes la même criticité ni le même rythme d'évolution.

| Critère | Architecture monolithique | Architecture BaaS modulaire de Prismatica |
| ------- | ------------------------- | ----------------------------------------- |
| Point d'entrée | Un serveur expose toutes les routes | WAF + Kong centralisent l'entrée publique |
| Sécurité | Les contrôles sont dans la même application | Gateway, guards, permissions ABAC et services privés |
| Évolution | Toute modification touche le même bloc | Chaque service évolue séparément |
| Bases de données | Souvent une base principale unique | PostgreSQL, MongoDB, Redis, MinIO et Trino selon l'usage |
| Panne partielle | Une erreur peut impacter toute l'application | Les pannes sont isolées par service |
| Scalabilité | Mise à l'échelle globale du serveur | Mise à l'échelle par plan : gateway, query, storage, analytics |
| Maintenance | Plus simple au début, plus lourde quand le projet grandit | Plus complexe au début, plus contrôlable ensuite |
| Réutilisabilité | Couplé au métier d'une application | Socle réutilisable pour plusieurs produits |

```mermaid
flowchart LR
  subgraph Mono[Monolithe]
    M[Serveur unique<br/>auth + API + fichiers + data + jobs]
    MDB[(Base unique)]
    M --> MDB
  end

  subgraph Modular[BaaS modulaire]
    GW[Gateway]
    A[Auth]
    Q[Query]
    S[Storage]
    B[Background]
    PG[(PostgreSQL)]
    MO[(MongoDB)]
    O[(MinIO)]
    GW --> A --> PG
    GW --> Q
    Q --> PG
    Q --> MO
    GW --> S --> O
    B -. asynchrone .-> PG
  end
```

Le choix modulaire n'est donc pas seulement technique. Il répond au besoin produit : Prismatica doit être capable d'ajouter de nouveaux adapters, de nouveaux types de vues, des dashboards publics, des intégrations, des services de fond ou de l'analytics sans casser le cœur d'authentification et de données.

### Avantages, contraintes et limites de l'approche BaaS

| Avantages | Explication pour Prismatica |
| --------- | --------------------------- |
| Réutilisabilité | Le même socle peut servir plusieurs applications ou clients |
| Sécurité renforcée | La gateway, les guards, les permissions serveur et l'isolation des services réduisent la surface d'attaque |
| Séparation des responsabilités | Chaque service a un rôle clair : auth, query, storage, permissions, logs |
| Scalabilité ciblée | Il est possible de renforcer seulement le service saturé |
| Tolérance aux pannes | Une panne de l'analytics ou de l'email ne doit pas bloquer l'auth ou le CRUD |
| Polyvalence data | PostgreSQL, MongoDB, Redis et MinIO sont utilisés selon leurs forces |
| Observabilité | Les métriques, logs et request IDs rendent le diagnostic plus précis |
| Autonomie produit | Le front-end peut consommer des briques prêtes sans créer une API métier complète |

| Contraintes | Impact | Réponse mise en place |
| ---------- | ------ | --------------------- |
| Plus de services à comprendre | Courbe d'apprentissage plus longue | Documentation, diagrammes, profils Compose |
| Latence réseau interne | Chaque appel inter-service ajoute un coût | Chemin critique court, cache L1/L2, coalescing |
| Débogage distribué | Une requête traverse plusieurs composants | `X-Request-ID`, logs structurés, observabilité |
| Gouvernance des contrats | Les routes et DTOs doivent rester stables | SDK public, DTOs, validations, versionnement des routes |
| Gestion des secrets | Plusieurs services ont des credentials | Vault, variables d'environnement, chiffrement des connexions |
| Déploiement plus complexe | Plusieurs conteneurs et dépendances | Docker Compose, healthchecks, profils par criticité |
| Risque de sur-architecture | Trop de services pour un petit besoin | Cœur BaaS minimal par défaut, services optionnels par profil |

La contrainte principale est donc la complexité opérationnelle. Pour la maîtriser, le projet ne lance pas tout par défaut : le cœur BaaS reste compact, puis les plans adapter, data, analytics, storage, background et observability sont activés seulement lorsque le besoin existe.

### Synthèse du chapitre back-end

Le back-end réalisé pour Prismatica constitue un socle BaaS complet. Il fournit une gateway publique sécurisée, un fournisseur d'identité, des services autonomes, un maillage privé de communication, plusieurs bases de données, du stockage objet, un système de permissions serveur et une architecture conteneurisée reproductible.

Ce choix est plus ambitieux qu'une API monolithique classique, mais il répond mieux au projet : Prismatica n'est pas seulement une application métier figée, c'est une plateforme de gestion de données capable de créer des interfaces, dashboards, widgets et intégrations à partir d'un socle back-end générique et sécurisé.

## CHAPITRE 5. Eléments de sécurité de l'application

### Authentification et gestion des rôles

### Validation des entrées et protection contre les injections

### Protections front-end et API

### Protection contre XSS et CSRF

### Conformité RGPD

## CHAPITRE 6. Jeu d'essai

## CHAPITRE 7. Veille technologique et sécurité

### Source de veille utilisées

### vulnérabilités identifiées dans l'écosystème technologique

### failles potentielles et correctifs appliqués

### conclusion

## CHAPITRE 8. Conclusion

## Annexes
