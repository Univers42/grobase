# Bilan DWWM RNCP 5 - Qualite, securite, performance et infrastructure

Date de synthese : 26 mai 2026  
Projet : Vite & Gourmand  
Public vise : dossier professionnel DWWM, jury, formateur, evaluateur technique

## Objectif du document

Ce document explique les travaux realises pendant la phase de stabilisation du projet : amelioration Lighthouse, securisation du frontend et du backend, correction des erreurs de code et de CI, refactorisation Docker de l'infrastructure, clarification du Makefile et mise en place d'une politique HTTPS/CA.

Il est redige dans un langage compatible avec une presentation de niveau DWWM RNCP niveau 5 : il explique le contexte, la methode, les choix techniques, les benefices pour le projet et les preuves de validation.

## Resume executif

Le projet avait besoin d'une phase de qualite avant livraison : certaines routes publiques obtenaient un score Lighthouse insuffisant, la securite frontend devait etre renforcee, l'authentification exposait encore trop de surface d'attaque, le deploiement Fly et les scripts d'exploitation etaient disperses, et la CI devait mieux proteger le projet.

Les travaux ont permis de :

- faire monter les pages publiques au-dessus de 90 dans les categories Lighthouse principales ;
- supprimer des pratiques a risque comme le stockage lisible du JWT cote navigateur ;
- proteger les flux authentifies avec cookies securises et jeton CSRF ;
- renforcer HTTPS, HSTS, CORS, CSP et la validation des URL de production ;
- documenter chaque faille detectee dans une archive dediee ;
- rendre l'infrastructure plus professionnelle avec des services Docker ranges par responsabilite ;
- dockeriser l'usage de Fly afin que l'environnement local ne depende plus de `flyctl` installe sur la machine ;
- refactoriser les tokens CSS `:root` pour rendre le design system plus coherent et maintenable ;
- securiser et completer le DevBoard pour que les admins et employes puissent gerer menus, plats, photos et relations depuis la base ;
- remettre les tests backend, les audits de dependances, les builds frontend/backend et les checks CI dans un etat reproductible.

## Situation de depart

Avant cette phase, plusieurs problemes limitaient la qualite du projet :

| Probleme observe | Risque pour le projet | Correction apportee |
|---|---|---|
| Score Lighthouse public proche de 60 | Mauvaise perception utilisateur, SEO faible, performance insuffisante | Optimisations frontend, accessibilite, SEO, build production et controle route par route |
| JWT stocke dans le navigateur | Risque de vol de session en cas de XSS | Passage a une authentification par cookie securise et HttpOnly |
| Token transmis dans URL SSE | Fuite possible dans logs, historique, proxy | Passage a `EventSource` avec cookies et `withCredentials` |
| CSP et politique d'URL incompletes | Risque XSS, mixed content, mauvaise configuration prod | Durcissement des headers, validation HTTPS et CI gate |
| HTTPS traite comme detail de deploiement | Risque de downgrade HTTP et cookies exposes | Enforcement applicatif, HSTS, verification CA, scripts de controle |
| Fly config et Dockerfiles disperses a la racine | Maintenance difficile, responsabilites floues | Refactorisation `infrastructure/services/*` |
| CI avec deploy Fly automatique | Risque de deploiement non souhaite a chaque push | Suppression du job de deploiement automatique |
| Erreurs TypeScript/Jest CI | Tests backend bloques | Correction des options Node/Jest et migration TypeScript 6 (`rootDir`) |
| CRUD DevBoard incomplet et trop generique | Gestion menu difficile, risque d'exposition de champs sensibles | Allowlist backend, tables menu ajoutees, Playwright et tests API |

## Methode de travail

La demarche a suivi une logique professionnelle : diagnostiquer, corriger, verifier, documenter.

1. Diagnostic

Les problemes ont ete identifies avec les outils adaptes : Lighthouse, builds Vite/NestJS, tests Jest, audits `npm audit`, diagnostics TypeScript, checks Docker Compose, scripts shell et verification HTTPS live.

2. Correction a la cause

Les corrections ont vise la cause racine. Par exemple, pour la securite auth, le probleme n'a pas ete masque cote UI : le modele d'authentification a ete revu pour eviter le stockage lisible du token dans le navigateur.

3. Validation reproductible

Les validations ont ete executees dans Docker quand c'etait necessaire, car le projet est concu pour fonctionner en environnement conteneurise.

4. Documentation

Les failles et decisions importantes ont ete archivees dans `docs/` afin que le projet puisse etre relu, maintenu et presente devant un jury.

## Amelioration Lighthouse

### Objectif

L'objectif etait d'obtenir un score superieur ou egal a 90 sur les categories principales de Lighthouse : Performance, Accessibilite, Bonnes pratiques et SEO.

Les routes publiques ont ete auditees, pas seulement la page d'accueil. Cela permet d'eviter un faux resultat positif ou seule la home serait optimisee.

### Scores obtenus pendant la validation

| Route | Performance | Accessibilite | Bonnes pratiques | SEO |
|---|---:|---:|---:|---:|
| `/` | 96 | 96 | 100 | 100 |
| `/menus` | 91 | 94 | 100 | 100 |
| `/contact` | 93 | 96 | 100 | 100 |
| `/commande` | 91 | 94 | 100 | 100 |
| `/mentions-legales` | 95 | 94 | 100 | 100 |
| `/cgv` | 95 | 94 | 100 | 100 |

### Comment le score a augmente

Le score a progresse grace a plusieurs familles d'actions.

#### Performance

- Build production Vite verifie route par route.
- Composants charges plus proprement, notamment les vues publiques et le portail.
- Images gerees par un composant `LazyImage` pour eviter de charger trop tot les medias non visibles.
- Reductions de risques de decalage visuel grace a des dimensions plus stables dans les composants.
- Nettoyage et harmonisation importante des CSS avec les tokens graphiques.
- Suppression de poids inutile et meilleure organisation des styles.

#### Accessibilite

- Structure plus lisible pour les pages publiques : titres, zones, navigation, contenu principal.
- Amelioration des contrastes et des etats visuels.
- Meilleure prise en charge du responsive pour eviter les chevauchements et les textes qui debordent.
- Composants plus comprehensibles pour la navigation clavier et les lecteurs d'ecran.

#### SEO

- Ajout et verification de fichiers publics utiles : `robots.txt`, `sitemap.xml`, manifeste web.
- Meilleure coherence des pages publiques et de leurs metadonnees.
- Verification que les pages principales repondent correctement en production build.

#### Bonnes pratiques

- Suppression de pratiques frontend dangereuses.
- Durcissement des headers de securite.
- Verification des URL de production pour eviter le `http://` public.
- Controle des routes avec Chrome headless et Lighthouse.

## Refactorisation des tokens CSS avec `:root`

### Objectif

Le frontend utilisait beaucoup de styles et de couleurs reutilises dans plusieurs composants. Pour rendre l'interface plus coherente, plus facile a maintenir et plus simple a expliquer, les valeurs graphiques ont ete centralisees sous forme de tokens CSS dans des blocs `:root`.

Les fichiers principaux sont :

- `View/src/styles/graphical_chart.css` pour les couleurs, fonds, textes, bordures et overlays ;
- `View/src/styles/graphical_chart_part2.css` pour la typographie, les espacements, les radius et les ombres ;
- `View/src/styles/graphical_chart_part3.css` pour les tailles de composants, z-index, transitions, grilles et alias pratiques.

### Comment fonctionne `:root`

En CSS, `:root` represente l'element racine du document, donc pratiquement toute l'application. Quand on declare une propriete comme :

```css
:root {
    --color-primary-500: #a855f7;
    --space-4: 1rem;
    --radius-lg: 0.5rem;
}
```

elle devient disponible partout avec `var(...)` :

```css
.button {
    background: var(--color-primary-500);
    padding: var(--space-4);
    border-radius: var(--radius-lg);
}
```

La cascade CSS applique ensuite ces valeurs dans les composants. Si on change le token a la racine, tous les composants qui l'utilisent changent de facon coherente.

### Ce qui a ete ameliore

- Les couleurs ont ete regroupees par role : primaire, secondaire, accent, succes, warning, danger, neutres et palette restaurant.
- Les tailles de texte ont ete normalisees pour eviter des valeurs arbitraires dans chaque composant.
- Les espacements utilisent une echelle commune (`--space-1`, `--space-2`, `--space-4`, etc.).
- Les radius, ombres, transitions, z-index et tailles de boutons/input/cartes sont centralises.
- Des alias semantiques comme `--text-primary`, `--bg-primary` ou `--border-default` rendent les composants plus lisibles.

### Benefices pour le projet

| Benefice | Explication |
|---|---|
| Coherence visuelle | Les composants partagent les memes couleurs, espacements et etats. |
| Maintenance | Une modification globale se fait dans un token au lieu de chercher des dizaines de valeurs. |
| Accessibilite | Les contrastes, tailles et etats focus sont plus faciles a controler. |
| Responsive | Les dimensions stables reduisent les chevauchements et les debordements. |
| Performance projet | Moins de duplication CSS et moins de corrections dispersees. |
| Dossier DWWM | Le design system devient explicable : on montre une organisation professionnelle, pas seulement du style au cas par cas. |

Cette refactorisation a participe a la hausse Lighthouse, surtout sur l'accessibilite, les bonnes pratiques d'interface et la stabilite visuelle.

## Securite frontend et backend

### Principe general

La securite a ete traitee comme une exigence transversale : frontend, backend, CI, deploiement et documentation.

Le but n'etait pas seulement de corriger une alerte, mais de reduire durablement la surface d'attaque.

### Archives de failles documentees

Chaque faille importante a ete documentee avec son contexte, son risque et sa correction :

| Archive | Sujet | Correction principale |
|---|---|---|
| `security-breach-frontend-001-token-storage.md` | JWT lisible dans le navigateur | Authentification par cookie securise |
| `security-breach-frontend-002-eventsource-token-url.md` | Token dans URL EventSource | SSE avec cookies et `withCredentials` |
| `security-breach-frontend-003-unsafe-dom-sink.md` | Sink DOM dangereux | Suppression/securisation du rendu non fiable |
| `security-breach-frontend-004-admin-data-leak.md` | Fuite de donnees admin | Nettoyage logs/console/tooltips |
| `security-breach-frontend-005-csp-header-hardening.md` | CSP et URL policy incompletes | Headers et validation d'origines renforces |
| `security-breach-frontend-006-ci-security-gates.md` | Pas assez de controles en CI | Ajout de checks de securite frontend |
| `security-breach-frontend-007-csrf-cookie-auth.md` | Cookie auth sans garde CSRF explicite | Jeton CSRF pour requetes sensibles |
| `security-breach-frontend-008-https-ca-enforcement.md` | HTTPS/CA pas assez impose | HSTS, redirection, verif CA, scripts |
| `security-breach-frontend-009-devboard-crud-data-exposure.md` | CRUD DevBoard trop generique | Allowlist, sanitization backend, RBAC, tests Playwright |

### Authentification

Avant, le frontend pouvait s'appuyer sur un token accessible par JavaScript. Cette approche est risquee : une faille XSS peut lire le token et le transmettre a un attaquant.

La correction a consiste a :

- placer le token d'acces dans un cookie securise ;
- utiliser `HttpOnly`, `Secure` en production et une duree de vie limitee ;
- conserver un token CSRF separe pour autoriser les requetes sensibles ;
- adapter le backend pour extraire le JWT depuis le cookie ou le bearer token selon le contexte ;
- adapter le frontend pour envoyer les requetes avec `credentials: 'include'`.

### Protection CSRF

Le passage aux cookies securises cree un nouveau risque : le CSRF. Il a donc ete traite explicitement.

Les requetes sensibles ajoutent un header `X-CSRF-Token`. Le backend verifie que le token CSRF correspond a ce qui est attendu. Cela evite qu'un site tiers declenche une action au nom d'un utilisateur connecte.

### CORS, Helmet et headers

Le backend a ete renforce avec :

- Helmet pour les headers de securite ;
- HSTS en production ;
- validation stricte des origines autorisees ;
- refus des URL publiques en `http://` en production ;
- limites de taille sur les corps de requete ;
- redirection HTTPS si le proxy signale une requete HTTP.

### Audits de dependances

Les dependances ont ete verifiees avec `npm audit`.

Corrections notables :

- mise a jour de `nodemailer` vers une version corrigee ;
- override de `@hono/node-server` vers une version corrigee pour traiter une alerte transitive liee a Prisma ;
- audits backend et frontend revenus a `0 vulnerabilities` au niveau verifie.

## DevBoard : gestion securisee des menus, plats et photos

### Objectif

Le besoin metier est simple : un admin ou un employe doit pouvoir enrichir la carte du traiteur depuis le DevBoard sans toucher au code. Il doit pouvoir creer un menu avec un titre, une description, des conditions, un nombre minimum de personnes, un prix par personne, une quantite disponible, une photo, puis rattacher des plats au menu.

### Probleme identifie

Avant la correction, le DevBoard affichait une interface de gestion menu partiellement statique. Le CRUD generique exposait bien certaines tables comme `Menu` et `Dish`, mais pas toute la logique metier necessaire : photos de menu, ingredients, allergenes, tables de liaison et relation menu-plat.

La securite devait aussi etre renforcee : masquer un champ sensible dans le tableau frontend ne suffit pas si l'API renvoie encore le champ dans le JSON.

### Correction backend

Le controller CRUD a ete transforme en API a politiques explicites :

- seules les tables autorisees sont exposees ;
- chaque table possede une liste de champs lisibles et ecrivables ;
- les tables systeme sensibles (`User`, `Role`, `Order`) sont en lecture seule depuis le CRUD DevBoard ;
- le champ `password` n'est plus expose dans le schema CRUD ;
- les resultats API sont nettoyes cote backend, pas seulement masques dans l'interface ;
- les URL media (`image_url`, `photo_url`, `icon_url`) doivent utiliser HTTPS, sauf localhost en developpement ;
- les ecritures sensibles restent protegees par cookie auth + CSRF ;
- les roles `admin` et `employee` ont acces au CRUD, les clients sont bloques.

### Tables metier exposees

Les tables utiles a la gestion traiteur sont maintenant disponibles dans le DevBoard :

| Table | Usage |
|---|---|
| `Menu` | Creation du menu : titre, description, conditions, prix, quantite, statut. |
| `MenuImage` | Ajout de photos, texte alternatif, ordre d'affichage, image principale. |
| `Dish` | Creation des plats qui composent les menus. |
| `MenuDish` | Table virtuelle controlee pour rattacher un plat a un menu. |
| `Ingredient` | Gestion des ingredients et stocks. |
| `MenuIngredient` | Quantite d'ingredient par personne pour un menu. |
| `DishIngredient` | Quantite d'ingredient dans un plat. |
| `DishAllergen` | Association plat/allergene. |
| `Diet`, `Theme`, `Allergen` | Classification et contraintes alimentaires. |

### Correction frontend

Le DevBoard admin et employe charge maintenant le vrai `DatabaseViewer` avec la table `Menu` selectionnee par defaut. L'employe voit une entree `Menus` dans son espace, et l'admin conserve `Gestion Menu`.

Le viewer supporte maintenant :

- les cles primaires simples et composites ;
- les tables en lecture seule ;
- les actions create/update/delete selon les droits de la table ;
- les champs read-only ;
- l'affichage des tables de liaison ;
- la suppression et l'edition avec une cle composite encodee proprement.

### Validation realisee

Validation Docker live :

- connexion employe avec le compte de test seed ;
- lecture du schema CRUD ;
- test de chaque endpoint expose : `users`, `roles`, `orders`, `menus`, `menu-images`, `menu-dishes`, `dishes`, `ingredients`, `menu-ingredients`, `dish-ingredients`, `dish-allergens`, `diets`, `themes`, `allergens`, `working-hours` ;
- verification CSRF : une creation sans `X-CSRF-Token` retourne `403` ;
- creation d'un plat ;
- creation d'un menu publie ;
- ajout d'une photo HTTPS ;
- rattachement du plat au menu via `MenuDish` ;
- relecture publique via `/api/menus/:id` avec `MenuImage` et `Dish` presents ;
- verification qu'un client obtient `403` sur `/api/crud/schema` ;
- nettoyage des donnees de test.

Validation Playwright :

- ajout de `@playwright/test` ;
- ajout de `View/playwright.config.ts` ;
- ajout du test `View/tests/e2e/devboard-menu-crud.spec.ts` ;
- execution reussie : `1` test Playwright passe sur le workflow CRUD menu.

Validation navigateur live :

- ouverture de `http://localhost:5173/dashboard` ;
- connexion employe ;
- ouverture de la categorie `Menus` ;
- chargement de la vue `Menus & Plats` ;
- table `Menu` selectionnee par defaut ;
- tables disponibles visibles, dont `MenuImage`, `MenuDish`, `Dish`, `Ingredient`, `MenuIngredient`, `DishIngredient` et `DishAllergen`.

## HTTPS, certificats CA et production

### Objectif

L'objectif etait de garantir que le site public utilise du HTTPS de confiance, avec un certificat delivre par une autorite reconnue comme Let's Encrypt, Fly managed certificates ou Cloudflare.

### Ce qui a ete mis en place

- Enforcement applicatif : le backend refuse les origines publiques non HTTPS en production.
- Redirection proxy-aware : si `X-Forwarded-Proto` indique HTTP, le backend renvoie une redirection permanente `308` vers HTTPS.
- HSTS : `Strict-Transport-Security: max-age=31536000; includeSubDomains; preload`.
- Scripts de verification : DNS, certificat CA, expiration, redirection HTTP vers HTTPS, HSTS, pages publiques.
- Config host : `.htaccess` pour Apache/OVH et exemple Nginx dans `docs/nginx-vite-gourmand-https.conf`.

### Risque restant cote hebergeur

Le code du projet ne peut pas installer un certificat CA a la place de l'hebergeur. Les derniers controles live montrent que les certificats Let's Encrypt sont presents, mais que l'hebergeur doit encore corriger :

- HSTS manquant sur les reponses live ;
- `http://www.vite-gourmand.fr` qui doit rediriger vers HTTPS ;
- DNS qui doit etre aligne avec la couche de production choisie.

Ce point est documente dans `docs/deployment.md` et dans l'archive de faille HTTPS.

## CI GitHub Actions et tests

### Objectif

La CI doit verifier le projet sans deployer automatiquement en production a chaque push.

### Actions realisees

- Correction de l'option Jest invalide `--localstorage-file`.
- Passage de la CI Node vers Node 22 pour respecter les contraintes des dependances recentes.
- Correction du build frontend qui ne trouvait pas le module de logs.
- Suppression du job de deploiement Fly automatique.
- Ajout de controles securite : HTTPS, HSTS, URL de production, scripts shell.
- Correction TypeScript 6 `TS5011` avec `rootDir` explicite dans `Back/tsconfig.json`.
- Ajout d'un test Playwright pour le workflow DevBoard menu CRUD.

### Resultats verifies

- Tests unitaires backend : 39 suites passees, 324 tests passes.
- Test Playwright DevBoard menu CRUD : 1 test passe.
- Build backend NestJS : OK.
- Build frontend Vite : OK.
- Audits backend/frontend : 0 vulnerabilite au niveau verifie.
- Docker production app image : build OK.
- `docker compose config` : OK.
- `make docker-build-dev` : OK.

## Refactorisation infrastructure

### Objectif

L'infrastructure devait etre lisible, maintenable et utilisable sans dependance globale sur la machine du developpeur.

Avant, plusieurs fichiers etaient a la racine : `Dockerfile`, `Dockerfile.dev`, `Dockerfile.bw`, `fly.toml`. Cette organisation fonctionnait, mais elle rendait moins claire la responsabilite de chaque service.

### Nouvelle organisation

La structure est maintenant organisee autour de contrats et de services :

```text
infrastructure/
├── contracts/
│   ├── secrets.md
│   └── transport-security.md
└── services/
    ├── app/
    ├── dev/
    ├── fly/
    ├── mongo/
    ├── postgres/
    └── secrets/
```

Chaque service possede son propre `Dockerfile`, son dossier `config/` et son dossier `scripts/`.

### Benefices

- Meilleure separation des responsabilites.
- Plus facile a expliquer en entretien technique.
- Plus facile a maintenir et a faire evoluer.
- Moins de fichiers critiques disperses a la racine.
- Docker devient le point d'entree unique pour les outils techniques.

## Dockerisation de Fly

### Probleme

Le projet ne devait pas dependre d'une installation locale de `flyctl`. Cela cree trop de differences entre les postes de developpement et la CI.

### Solution

Un service Docker `fly` a ete ajoute :

```bash
docker compose --profile tools run --rm fly flyctl version
```

La configuration Fly se trouve maintenant ici :

```text
infrastructure/services/fly/config/fly.toml
```

Le token peut etre stocke localement dans `.env.production` avec `FLY_API_TOKEN` ou `FLY_ACCESS_TOKEN`. Le conteneur convertit automatiquement `FLY_API_TOKEN` en `FLY_ACCESS_TOKEN`, qui est le nom attendu par `flyctl`.

### Benefices

- Pas besoin d'installer Fly CLI sur la machine.
- Meme comportement pour tous les developpeurs.
- Secrets non commites.
- Commandes Make plus simples.
- Deploiement manuel controle.

## Refactorisation du Makefile

### Objectif

Le Makefile principal etait trop volumineux. Il a ete decoupe par domaine dans `mk_extensions/`.

### Exemples de domaines

- backend ;
- frontend ;
- Docker ;
- base de donnees ;
- logs ;
- tests ;
- securite ;
- deploiement ;
- outils de diagnostic.

### Benefices

- Lecture plus simple.
- Ajout de commandes plus facile.
- Moins de conflits lors des modifications.
- Meilleure presentation en dossier professionnel : on voit la structuration par responsabilite.

## Corrections backend et qualite de code

### Corrections importantes

- Correction des erreurs Jest/Node en CI.
- Correction de TS5011 avec `rootDir` explicite.
- Conservation du layout attendu `dist/src/main.js` pour ne pas casser `start:prod`.
- Build NestJS verifie.
- Tests unitaires verifies.
- Audits de dependances corriges.

### Pourquoi c'est important

Un projet professionnel ne doit pas seulement fonctionner en local : il doit aussi se compiler, se tester et se construire automatiquement. Ces corrections reduisent le risque de regression au moment de la livraison.

## Benefices globaux pour le projet

| Axe | Benefice utilisateur | Benefice technique |
|---|---|---|
| Performance | Pages plus rapides, navigation plus fluide | Build optimise, meilleur controle du poids frontend |
| Accessibilite | Interface plus lisible et utilisable | Meilleure conformite aux bonnes pratiques web |
| SEO | Meilleure indexation potentielle | Sitemap, robots, pages publiques propres |
| Securite | Sessions mieux protegees | Cookies securises, CSRF, CSP, HSTS, CORS |
| DevBoard | Menus et plats gerables par le staff | CRUD allowliste, relations menu-plat, tests Playwright |
| CI | Moins de regressions | Tests, audits et builds automatises |
| Infrastructure | Deploiement plus fiable | Docker Compose, services separes, Fly dockerise |
| Maintenance | Projet plus comprehensible | Documentation, contrats, Makefile modulaire |

## Competences DWWM RNCP niveau 5 mobilisees

Ce travail peut etre presente dans le dossier professionnel comme une realisation transversale.

### Developper la partie front-end d'une application web ou web mobile securisee

Elements demonstrables :

- optimisation des pages publiques ;
- amelioration Lighthouse ;
- accessibilite et responsive ;
- securisation des appels API ;
- retrait du stockage JWT lisible ;
- verification des routes publiques.

### Developper la partie back-end d'une application web ou web mobile securisee

Elements demonstrables :

- auth JWT/cookie ;
- protection CSRF ;
- CORS et headers securite ;
- validation HTTPS des origines ;
- tests unitaires backend ;
- correction TypeScript/Jest/CI ;
- audits de dependances.

### Mettre en place une demarche qualite

Elements demonstrables :

- tests automatises ;
- tests Playwright sur un workflow metier ;
- CI GitHub Actions ;
- audits `npm audit` ;
- controle Lighthouse ;
- documentation des failles ;
- verification Docker Compose ;
- scripts de diagnostic et de verification HTTPS.

### Maintenir et deployer une application de maniere professionnelle

Elements demonstrables :

- Docker Compose comme environnement reproductible ;
- separation des services dans `infrastructure/services` ;
- gestion des secrets hors Git ;
- Fly CLI dockerise ;
- deploiement manuel controle ;
- contrats d'infrastructure.

## Formulation possible pour le dossier professionnel

Exemple de formulation :

> Dans le cadre de mon projet Vite & Gourmand, j'ai realise une phase de stabilisation technique avant livraison. J'ai commence par diagnostiquer les problemes de performance, d'accessibilite, de securite et de CI. J'ai ensuite corrige les failles frontend et backend, notamment le stockage du JWT, la protection CSRF, les headers HTTP, la politique HTTPS, les erreurs TypeScript/Jest et le CRUD DevBoard. J'ai aussi refactorise l'infrastructure en services Docker et les tokens CSS `:root` pour rendre le projet plus maintenable. Les validations ont ete realisees avec Lighthouse, Jest, Playwright, npm audit, Docker Compose et les builds de production. Cette demarche a permis d'obtenir des scores Lighthouse superieurs a 90 sur les pages publiques, de valider 39 suites backend et un scenario Playwright metier, de revenir a 0 vulnerabilite detectee par audit au niveau verifie, et de rendre le projet plus fiable pour une livraison professionnelle.

## Preuves techniques a presenter

| Preuve | Commande ou fichier |
|---|---|
| Scores Lighthouse | Rapport ou captures des routes publiques |
| Tests backend | `npm test` dans `Back/` |
| Test Playwright menu CRUD | `PLAYWRIGHT_SKIP_WEB_SERVER=1 PLAYWRIGHT_API_URL=http://localhost:3000 npx playwright test tests/e2e/devboard-menu-crud.spec.ts` |
| DevBoard live | `http://localhost:5173/dashboard`, compte employee, categorie `Menus` |
| Build frontend | `npm run build` dans `View/` |
| Build backend | `npm run build` dans `Back/` |
| Audit dependances | `npm audit --audit-level=moderate` |
| Verification HTTPS | `scripts/security/verify-production-https.sh` |
| Infrastructure Docker | `docker compose --profile dev --profile tools --profile production config` |
| Fly dockerise | `docker compose --env-file .env.production --profile tools run --rm fly flyctl version` |
| Archives de failles | `docs/security-breach-frontend-*.md` |

## Conclusion

Cette phase a transforme le projet en une application plus presentable professionnellement : meilleure qualite percue, meilleures garanties de securite, tests reproductibles, infrastructure plus claire et documentation exploitable.

Pour un jury DWWM, le point important est la demarche : identifier les risques, choisir une solution adaptee, implementer proprement, verifier avec des outils, puis documenter. C'est cette chaine complete qui montre une posture de developpeur web et web mobile de niveau professionnel.