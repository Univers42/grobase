# 🤝 Guide de Contribution - Vite & Gourmand

Merci de votre intérêt pour contribuer à Vite & Gourmand ! Ce guide vous aidera à comprendre notre workflow et nos standards.

---

## 📋 Table des Matières

1. [Code de Conduite](#code-de-conduite)
2. [Comment Contribuer](#comment-contribuer)
3. [Standards de Code](#standards-de-code)
4. [Architecture](#architecture)
5. [Git Workflow](#git-workflow)
6. [Tests](#tests)
7. [Documentation](#documentation)

---

## Code de Conduite

### Nos Valeurs
- ✅ Respect et bienveillance
- ✅ Collaboration et entraide
- ✅ Qualité avant quantité
- ✅ Accessibilité pour tous
- ✅ Innovation responsable

### Comportements Attendus
- Communiquer de manière constructive
- Accepter les critiques avec ouverture
- Se concentrer sur ce qui est meilleur pour la communauté
- Faire preuve d'empathie envers les autres

---

## Comment Contribuer

### Types de Contributions

#### 🐛 Signaler un Bug
1. Vérifier qu'il n'existe pas déjà dans les issues
2. Créer une nouvelle issue avec le template
3. Inclure:
   - Description détaillée
   - Étapes de reproduction
   - Comportement attendu vs actuel
   - Screenshots si applicable
   - Environnement (navigateur, OS)

#### ✨ Proposer une Fonctionnalité
1. Ouvrir une issue de discussion
2. Décrire le problème que ça résout
3. Proposer une solution
4. Attendre feedback avant de coder

#### 📝 Améliorer la Documentation
- README.md
- API_DOCUMENTATION.md
- ARCHITECTURE.md
- Commentaires dans le code
- JSDoc pour les fonctions

#### 🎨 Améliorer le Design
- Respecter la charte graphique
- Maintenir l'accessibilité (WCAG AA)
- Mobile-first approach
- Consistency avec Shadcn/ui

---

## Standards de Code

### TypeScript

#### Nomenclature
```typescript
// PascalCase pour les types et composants
type User = { ... }
interface OrderProps { ... }
const MenuCard: React.FC<MenuCardProps> = () => { ... }

// camelCase pour les variables et fonctions
const userName = 'Jean';
const fetchUserOrders = async () => { ... }

// SCREAMING_SNAKE_CASE pour les constantes
const MAX_FILE_SIZE = 5 * 1024 * 1024;
const API_BASE_URL = 'https://...';
```

#### Types
```typescript
// ✅ FAIRE - Types explicites
const calculateTotal = (price: number, quantity: number): number => {
  return price * quantity;
};

// ❌ ÉVITER - Types implicites
const calculateTotal = (price, quantity) => {
  return price * quantity;
};
```

#### Interfaces vs Types
```typescript
// ✅ Utiliser interface pour les objets
interface User {
  id: string;
  name: string;
}

// ✅ Utiliser type pour les unions
type Status = 'pending' | 'accepted' | 'completed';

// ✅ Utiliser type pour les fonctions
type FetchFunction = (id: string) => Promise<Data>;
```

### React

#### Composants Fonctionnels
```typescript
// ✅ FAIRE - Composant avec types et props destructurées
type ButtonProps = {
  label: string;
  onClick: () => void;
  disabled?: boolean;
};

const Button: React.FC<ButtonProps> = ({ label, onClick, disabled = false }) => {
  return (
    <button onClick={onClick} disabled={disabled}>
      {label}
    </button>
  );
};

export default Button;
```

#### Hooks
```typescript
// ✅ Ordre des hooks (toujours le même)
const MyComponent = () => {
  // 1. State hooks
  const [data, setData] = useState<Data | null>(null);
  const [loading, setLoading] = useState(false);
  
  // 2. Context hooks
  const { user } = useAuth();
  
  // 3. Ref hooks
  const inputRef = useRef<HTMLInputElement>(null);
  
  // 4. Effect hooks
  useEffect(() => {
    fetchData();
  }, []);
  
  // 5. Custom hooks
  const { isOnline } = useNetworkStatus();
  
  // 6. Event handlers
  const handleSubmit = (e: React.FormEvent) => { ... };
  
  // 7. Render
  return <div>...</div>;
};
```

#### Gestion d'État
```typescript
// ✅ FAIRE - État local simple
const [count, setCount] = useState(0);

// ✅ FAIRE - État complexe groupé
const [form, setForm] = useState({
  email: '',
  password: ''
});

// ❌ ÉVITER - Trop d'états séparés
const [email, setEmail] = useState('');
const [password, setPassword] = useState('');
const [firstName, setFirstName] = useState('');
const [lastName, setLastName] = useState('');
// ... Utiliser plutôt un objet
```

### Tailwind CSS

#### Classes Ordonnées
```tsx
// ✅ FAIRE - Ordre logique
<div className="
  flex items-center justify-between
  w-full max-w-4xl
  px-4 py-6
  bg-white rounded-lg shadow-md
  hover:shadow-lg
  transition-shadow
">

// ❌ ÉVITER - Désorganisé
<div className="shadow-md w-full rounded-lg bg-white hover:shadow-lg py-6 flex px-4 max-w-4xl transition-shadow items-center justify-between">
```

#### Responsive Design
```tsx
// ✅ FAIRE - Mobile-first
<div className="
  grid grid-cols-1
  md:grid-cols-2
  lg:grid-cols-3
  gap-4
">

// ❌ ÉVITER - Desktop-first
<div className="
  grid grid-cols-3
  md:grid-cols-2
  sm:grid-cols-1
">
```

#### Réutilisation
```tsx
// ✅ FAIRE - Composants réutilisables
const CardContainer: React.FC = ({ children }) => (
  <div className="bg-white rounded-lg shadow-md p-6">
    {children}
  </div>
);

// ❌ ÉVITER - Duplication
<div className="bg-white rounded-lg shadow-md p-6">...</div>
<div className="bg-white rounded-lg shadow-md p-6">...</div>
```

### Backend (Deno + Hono)

#### Routes
```typescript
// ✅ FAIRE - Routes organisées par domaine
// === AUTH ROUTES ===
app.post('/make-server-e87bab51/signup', ...);
app.post('/make-server-e87bab51/login', ...);

// === MENU ROUTES ===
app.get('/make-server-e87bab51/menus', ...);
app.post('/make-server-e87bab51/menus', ...);
```

#### Error Handling
```typescript
// ✅ FAIRE - Gestion d'erreurs complète
app.post('/orders', async (c) => {
  try {
    const body = await c.req.json();
    
    // Validation
    if (!body.menuId) {
      return c.json({ error: 'menuId est requis' }, 400);
    }
    
    // Business logic
    const order = await createOrder(body);
    
    // Logging
    console.log(`Order created: ${order.id}`);
    
    return c.json({ order });
  } catch (error) {
    console.error(`Error creating order: ${error}`);
    return c.json({ error: 'Erreur lors de la création' }, 500);
  }
});
```

#### Authentication Middleware
```typescript
// ✅ FAIRE - Middleware réutilisable
const requireAuth = async (c: Context, next: Next) => {
  const { user, error } = await verifyAuth(c.req.raw);
  if (error || !user) {
    return c.json({ error: 'Non autorisé' }, 401);
  }
  c.set('user', user);
  await next();
};

app.get('/protected', requireAuth, async (c) => {
  const user = c.get('user');
  // ...
});
```

---

## Architecture

### Structure des Dossiers
```
/components
  /ui           → Composants de base (Shadcn)
  [Feature].tsx → Composants de fonctionnalité
  
/supabase/functions/server
  index.tsx     → Serveur principal
  [module].tsx  → Modules séparés si nécessaire
  
/utils
  /supabase     → Configuration Supabase
  [helper].ts   → Fonctions utilitaires
```

### Séparation des Responsabilités

#### Composants
- **UI Components** (`/components/ui`): Boutons, inputs, cards (pas de logique métier)
- **Feature Components** (`/components`): Logique métier, state management
- **Layout Components**: Navbar, Footer (structure globale)

#### Backend
- **Routes**: Définition des endpoints
- **Controllers**: Logique métier
- **Services**: Interactions avec la base de données
- **Middleware**: Authentication, logging, CORS

---

## Git Workflow

### Branches

```
main
├── develop
│   ├── feature/user-authentication
│   ├── feature/order-system
│   ├── bugfix/menu-filter
│   └── hotfix/login-error
```

### Conventions de Nommage

```bash
# Nouvelles fonctionnalités
feature/nom-de-la-fonctionnalite

# Corrections de bugs
bugfix/nom-du-bug

# Corrections urgentes en production
hotfix/nom-du-hotfix

# Améliorations
enhancement/nom-de-amelioration

# Refactoring
refactor/nom-du-refactor
```

### Commits

#### Format
```
<type>(<scope>): <subject>

<body>

<footer>
```

#### Types
- **feat**: Nouvelle fonctionnalité
- **fix**: Correction de bug
- **docs**: Documentation
- **style**: Formatage (pas de changement de code)
- **refactor**: Refactoring
- **test**: Ajout de tests
- **chore**: Maintenance

#### Exemples
```bash
# ✅ FAIRE
feat(orders): add delivery fee calculation
fix(auth): resolve token expiration issue
docs(api): update authentication endpoints

# ❌ ÉVITER
fixed stuff
updated code
changes
```

### Pull Requests

#### Template
```markdown
## Description
Brève description des changements

## Type de changement
- [ ] Bug fix
- [ ] Nouvelle fonctionnalité
- [ ] Breaking change
- [ ] Documentation

## Checklist
- [ ] Code compilé sans erreurs
- [ ] Tests ajoutés/mis à jour
- [ ] Documentation mise à jour
- [ ] Respecte les standards de code
- [ ] Testé sur mobile et desktop
- [ ] Accessibilité vérifiée

## Screenshots (si applicable)
[Images]

## Notes additionnelles
Informations supplémentaires
```

---

## Tests

### Types de Tests

#### Tests Unitaires
```typescript
// Example avec Jest/Vitest
describe('calculateDeliveryFee', () => {
  it('should return 0 for Bordeaux', () => {
    expect(calculateDeliveryFee('Bordeaux')).toBe(0);
  });
  
  it('should calculate fee for other cities', () => {
    expect(calculateDeliveryFee('Mérignac', 10)).toBe(10.9);
  });
});
```

#### Tests d'Intégration
```typescript
describe('Order Creation Flow', () => {
  it('should create order with correct pricing', async () => {
    const order = await createOrder({
      menuId: 'menu-1',
      numberOfPeople: 15,
      deliveryCity: 'Bordeaux'
    });
    
    expect(order.totalPrice).toBe(675); // 450 * 1.5
    expect(order.deliveryFee).toBe(0);
  });
});
```

### Coverage
- **Target**: 80% de couverture minimum
- **Priorité**: Logique métier critique
- **Exclure**: Composants UI simples

---

## Documentation

### Code Comments

#### JSDoc
```typescript
/**
 * Calcule le prix total d'une commande incluant les réductions et frais de livraison
 * @param menuPrice - Prix de base du menu
 * @param numberOfPeople - Nombre de personnes
 * @param minPeople - Nombre minimum de personnes pour le menu
 * @param deliveryCity - Ville de livraison
 * @returns Prix total calculé
 */
function calculateTotalPrice(
  menuPrice: number,
  numberOfPeople: number,
  minPeople: number,
  deliveryCity: string
): number {
  // Implementation
}
```

#### Commentaires Inline
```typescript
// ✅ FAIRE - Expliquer le "pourquoi"
// Appliquer réduction de 10% si 5+ personnes au-dessus du minimum
// selon les conditions commerciales définies dans les CGV
if (numberOfPeople >= minPeople + 5) {
  price = price * 0.9;
}

// ❌ ÉVITER - Répéter le code
// Multiplier le prix par 0.9
price = price * 0.9;
```

### README
- Vue d'ensemble du projet
- Instructions d'installation
- Guide de démarrage rapide
- Exemples d'utilisation

### API Documentation
- Tous les endpoints documentés
- Exemples de requêtes/réponses
- Codes d'erreur
- Authentication requirements

---

## Checklist de Contribution

Avant de soumettre une PR, vérifier :

- [ ] ✅ Code compilé sans erreurs TypeScript
- [ ] ✅ Aucun warning dans la console
- [ ] ✅ Tests écrits et passant
- [ ] ✅ Documentation mise à jour
- [ ] ✅ Commits bien formatés
- [ ] ✅ Code review effectué
- [ ] ✅ Accessible (WCAG AA)
- [ ] ✅ Responsive (mobile, tablet, desktop)
- [ ] ✅ Performance vérifiée
- [ ] ✅ Sécurité évaluée

---

## Ressources

### Documentation Technique
- [React Documentation](https://react.dev/)
- [TypeScript Handbook](https://www.typescriptlang.org/docs/)
- [Tailwind CSS](https://tailwindcss.com/docs)
- [Shadcn/ui](https://ui.shadcn.com/)
- [Supabase Docs](https://supabase.com/docs)
- [Deno Manual](https://deno.land/manual)
- [Hono Documentation](https://hono.dev/)

### Outils
- **VS Code**: Éditeur recommandé
- **Extensions**:
  - ESLint
  - Prettier
  - Tailwind CSS IntelliSense
  - TypeScript Vue Plugin (Volar)

### Standards
- [WCAG 2.1](https://www.w3.org/WAI/WCAG21/quickref/) - Accessibilité
- [RGPD](https://www.cnil.fr/fr/rgpd-de-quoi-parle-t-on) - Protection des données
- [Conventional Commits](https://www.conventionalcommits.org/) - Format de commits

---

## Questions ?

- 📧 Email: dev@vite-gourmand.fr
- 💬 Discord: [Lien vers serveur]
- 🐛 Issues: [GitHub Issues]

---

**🎉 Merci de contribuer à Vite & Gourmand !**

Votre aide est précieuse pour améliorer cette plateforme et offrir la meilleure expérience possible à nos utilisateurs.
