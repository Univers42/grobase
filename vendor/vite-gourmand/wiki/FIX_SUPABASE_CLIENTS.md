# Correction des Erreurs Supabase

## Problèmes Identifiés

### 1. Multiple instances de GoTrueClient
**Symptôme** : Avertissement dans la console
```
Multiple GoTrueClient instances detected in the same browser context
```

**Cause** : Plusieurs créations de clients Supabase dans différents fichiers :
- `/App.tsx` créait un nouveau client
- `/utils/orderManager.ts` créait un nouveau client
- `/supabase/functions/server/index.tsx` créait de nouveaux clients à chaque appel de `getServiceClient()` et `getAnonClient()`

### 2. Erreur de récupération des commandes
**Symptôme** : Message d'erreur dans la console
```
Error fetching orders
```

**Cause** : 
- Routes d'orders dupliquées entre `/supabase/functions/server/index.tsx` et `/supabase/functions/server/orders.ts`
- Ancien système de stockage (`orders`) vs nouveau système (`orders:list` + `order:${id}`)
- Conflit de routage et incompatibilité de formats de données

## Solutions Appliquées

### 1. Client Supabase Singleton (Frontend)

**Fichier créé** : `/utils/supabase/client.ts`
```typescript
// Singleton pour éviter les instances multiples
let supabaseInstance: SupabaseClient | null = null;

export function getSupabaseClient(): SupabaseClient {
  if (!supabaseInstance) {
    supabaseInstance = createSupabaseClient(
      `https://${projectId}.supabase.co`,
      publicAnonKey
    );
  }
  return supabaseInstance;
}

export const supabase = getSupabaseClient();
```

**Fichiers modifiés** :
- `/App.tsx` : Utilise maintenant `import { supabase } from './utils/supabase/client'`
- `/utils/orderManager.ts` : Utilise maintenant le client singleton

### 2. Clients Supabase Singletons (Backend)

**Fichier modifié** : `/supabase/functions/server/index.tsx`

Avant :
```typescript
const getServiceClient = () => {
  return createClient(...);  // ❌ Nouvelle instance à chaque appel
};
```

Après :
```typescript
let serviceClient: any = null;
let anonClient: any = null;

const getServiceClient = () => {
  if (!serviceClient) {
    serviceClient = createClient(...);  // ✅ Singleton
  }
  return serviceClient;
};
```

### 3. Consolidation des Routes d'Orders

**Suppression des routes dupliquées** dans `/supabase/functions/server/index.tsx` :
- ❌ Supprimé : Routes GET/POST `/make-server-e87bab51/orders` (ancien format)
- ✅ Conservé : Router monté `/make-server-e87bab51/orders` (nouveau format avec KV store)

Le nouveau système utilise :
- `orders:list` : Liste des IDs de commandes
- `order:${orderId}` : Données de chaque commande
- `user:${userId}:orders` : Commandes par utilisateur

### 4. Migration des Données

**Route de migration ajoutée** : `POST /make-server-e87bab51/migrate-orders`

Cette route migre automatiquement les commandes de l'ancien format vers le nouveau :
- Ancien format : `kv.get('orders')` retourne un tableau
- Nouveau format : `kv.get('orders:list')` + `kv.get('order:${id}')`

La migration est appelée automatiquement au démarrage de l'application dans `/App.tsx`.

### 5. Amélioration du Logging

Ajout de logs détaillés dans :
- `/supabase/functions/server/orders.ts` : Logs pour GET et POST
- `/utils/orderManager.ts` : Logs pour les appels API

Format des logs :
```
[ORDERS] Fetching orders with filters...
[ORDERS] Found X order IDs in orders:list
[ORDERS] ✅ Successfully fetched X orders
```

## Bénéfices

1. **Performance** : Une seule instance de client Supabase = moins de mémoire, meilleur caching
2. **Stabilité** : Plus de conflits entre instances multiples
3. **Debugging** : Logs détaillés pour identifier rapidement les problèmes
4. **Compatibilité** : Migration automatique des données vers le nouveau format
5. **Maintenabilité** : Code plus propre, pas de duplication de routes

## Test des Corrections

Pour vérifier que tout fonctionne :

1. **Vérifier l'absence d'avertissements** dans la console
   - Ne devrait plus voir "Multiple GoTrueClient instances"

2. **Vérifier le chargement des commandes**
   - Ouvrir l'espace admin ou employé
   - Accéder au Kanban
   - Les commandes doivent s'afficher correctement

3. **Vérifier la création de commandes**
   - Créer une nouvelle commande
   - Elle doit apparaître immédiatement dans le Kanban

4. **Vérifier les logs**
   - Ouvrir la console du navigateur
   - Chercher les logs `[ORDERS]` et `[orderManager]`
   - Vérifier qu'il n'y a pas d'erreurs

## Notes Techniques

- Le client singleton Supabase est maintenant exporté depuis `/utils/supabase/client.ts`
- Tous les composants doivent importer `supabase` depuis ce fichier unique
- La migration des commandes est idempotente (peut être exécutée plusieurs fois sans problème)
- Les anciennes commandes ne sont pas supprimées pour éviter toute perte de données
