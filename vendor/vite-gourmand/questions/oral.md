Pourquoi 0 test front ?
-	priorité stratégique pour un dev en autonomie, focus sur les tests back-end qui sécurisent les données

Comment tu mettrais en place Sentry/Playwright si tu rejoignais une équipe demain ?
Ta procédure  de rollback réelle, même informelle (git revert + Docker rebuild)

PgBouncer port 6543 vs direct 5432 - pourquoi deux URL ? Que se passe-t-il si tu mets `pgbouncer=true` sur le port direct?

Bitwarden  CLI -- comment gères-tu la rotation des secrets ? Que se passe-t-il si son compte Bitwarden est compromis ?

Dockerfile multi-stage 3 étapes: explique le gain en taille d'image vs un Dockerfile simple. Quelle eest la taille finale de ton image de production ?

Github actions - Pourquoi les services `postgres:15` et `mongo:6` en CI utilisent dese version différentes de la prod ? n'est ce pas un risque ?

Sur le maquettage & l'UX (CP2)
1. toekns CSS en 3 fichiers - donne un exemple concret où l'alias sémantique a évité une refonte. Comment as-tu géré la palette pour les daltoniens ?
3. WCAG AA - Quels critères précis as-tu validés ? As-tu utilisé un outil automatique ( axe-core, lightouse) ou audité manuellement
3. Schémad d'entrainement des maquettes --  REAC l'exige peux-tu le montrer ? A préparer un diagramme de navigation simple, même refait après coup

## Sur le ffront-end statique & dynamique (CP3+CP4)
1. 0 test front-end - c'est la limite que l'on assume. si on rejoint une équipe demain, par où on commencerait ?
-	Réponse: Vitest + Testing Library sur les hooks critiques, Playwright sur 3-4 parcours e2e.)
- kanban DnD avec restore on fail - Décris le flow eact: optimistic UI, appel API, gestion d'erreur, rollback. Comment évites tu les conflits si 2 admins déplacent la même carte en même temps ? (verrouillage pessimiste, ou gestion de version dans la DB)
3. AI Menu composer OpenAI - Comment protèges tu la clé API ? combien coute un appel ? Que se passe-t-il si OpenAI est down ?
4. SSE EventSource DevBoard - Pourquoi SSE et pas WebSocket ? Que se passe-t-il si la connexion est coupée ? y a-t-il une reconnaisasance automatique ?
5. Validatoin HTML5 + class-validator - donne un example où la validation côté serveur a rattrapé une faille de la validation côté client.

## Sur la base de données (CP5)
1. 44 modèles Prisma - montre-moi le mèle le plux complexe et explique ses relations pourquoi avoir choisi cette modélisation plutot qu'une autre ?
2. Anonymisation RGPD transactionnelle - Décris le SQL/Prismatica exact. Que se passe-t-il se la transaction échoue en milieu dde parcours ? lLes données sont-elles dans une état cohérent ?

Sauvegarde/restauration - comment restaurerais-tu la production en cas de perte de données ? Quel est ton RPO/RTO?

## Sur l'accés aux données (CP6)
1. Garde "superadmin contourne" -- c'est un anti-pattern de sécurité classic (god mode). Comment l'auditerait un RSSI ? Comment tu logues les actions superadmin?
2. TTL mongo 90 jours sur les audits - la CNIL recommmande quelle durée pour les logs d'authentification ? es-tu conforme ?

## Sur le backend & le déploiement (CP7 + CP8)
1. mACHINE A ÉTATS DES COMMANDES - dessine les transitions. Que se passe-t-il si une transition invalide est demandée par l'API ? y a-t-il un test unitaire pour chaque transition ?
2. Prisma db push au lieu de migrate deploy - explique le reisque en production. Comment tu rejouerais ton schéma sur une nouvelle instance ?
3. Pas sentry ni de rollback formel _ c'est la limite assumé. Concrètement, si demain à 3h du matin une nouvelle release casse les paiements comment tu détectes et comment tu rétablis le service ?

---
**conseil oral géneral**: pour chaque limite que tu as assumé, prépare une réponse clare en 3 temps --- (1) ce que j'ai fait, (2) pourquoi je l'ai fait comme ca dans un contexte d'autoformation, (3) ce que je ferais en équipe avec budget.


20 questions recalibrées niveau DWWM (Bac+2)
Sur le projet en général

    Présente-moi Vite Gourmand en 2 minutes — c'est quoi, à qui c'est destiné, qu'est-ce que ça fait.
    Pourquoi as-tu choisi ce projet ? Qu'est-ce que tu voulais apprendre ?
    Quelle a été la difficulté que tu as mis le plus de temps à résoudre ? Comment tu t'y es pris ?

Sur l'environnement (CP1)

    C'est quoi Docker, en tes mots ? Pourquoi tu l'as utilisé ?
    Git, tu l'utilises comment ? Tu travailles sur des branches ? Tu fais des commits comment ?

Sur le maquettage (CP2)

    Montre-moi une maquette et explique pourquoi tu as fait ces choix de couleurs/typo.
    C'est quoi l'accessibilité pour toi ? Donne un exemple concret de ce que tu as mis en place.
    Mobile-first, ça veut dire quoi ? Pourquoi c'est important ?

Sur le front (CP3 + CP4)

    Explique-moi ce qui se passe quand un client clique sur "Ajouter au panier". (Le jury veut suivre le flow : event → state → API → UI update.)
    HTML sémantique, c'est quoi la différence entre <div> et <section> ?
    Tu utilises React Context. C'est quoi, à quoi ça sert ? Donne un exemple dans ton projet.
    Tailwind, pourquoi tu as choisi ça plutôt que du CSS classique ?

Sur la base de données (CP5)

    Pourquoi PostgreSQL et MongoDB en parallèle ? Qu'est-ce qui va dans l'un et qu'est-ce qui va dans l'autre ?
    C'est quoi une clé étrangère ? Montre-moi un exemple dans ton schéma.
    Tu stockes les mots de passe comment ? Pourquoi pas en clair ?

Sur le back-end (CP6 + CP7)

    C'est quoi JWT ? Comment ça marche pour ton authentification ?
    Quand un utilisateur essaie d'accéder à /admin, comment tu vérifies qu'il a le droit ?
    C'est quoi une transaction en base de données ? Tu en as utilisé où dans ton projet ?

Sur le déploiement (CP8)

    Si je veux installer ton projet sur ma machine demain, qu'est-ce que je fais ? (Réponse attendue : clone le repo, lance Docker Compose, ça démarre.)
    Que se passe-t-il quand tu pushes du code sur la branche main ? (CI tourne, tests, etc.)

Conseils pour préparer l'oral

    Pas besoin de tout savoir — tu peux dire "je ne sais pas, mais voici comment je chercherais" et c'est valorisé.
    Parle de ce que tu as fait toi, avec tes mots. Si tu cites un terme technique, sois prêt à l'expliquer simplement.
    Le jury est bienveillant — ils veulent que tu réussisses, pas te piéger.
    Prépare 2-3 anecdotes : un bug que tu as résolu, un choix technique que tu as changé en cours de route, une chose dont tu es fier.

Sur les 5 questions vraiment plus pointues que j'avais mises (RPO/RTO, audit RSSI, conflits Kanban, OpenAI down, validation client/serveur exploitable) — garde-les dans un coin au cas où le jury creuse, mais elles ne sont pas attendues.