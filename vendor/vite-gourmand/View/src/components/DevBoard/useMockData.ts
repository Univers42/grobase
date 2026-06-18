/**
 * useMockData - Temporary mock data hook
 * Returns test data based on category
 */

import type { TestCategory } from '../features/qa/sidebar';
import type { TestItem } from '../features/qa/test-cards';
import type { AutoTest } from '../features/qa/automatic-tests';

export function useMockData(category: TestCategory) {
  const tests: TestItem[] = [
    {
      id: '1',
      name: 'Authentification',
      description: 'Connexion, inscription, réinitialisation mot de passe, OAuth',
      status: 'pending',
      type: 'scenario',
      testPath: '/scenario/auth',
    },
    {
      id: '2',
      name: 'Validation Formulaire',
      description: 'Test du formulaire de contact - validation, soumission',
      status: 'pending',
      type: 'scenario',
      testPath: '/scenario/form',
    },
    {
      id: '3',
      name: 'Minitalk Client-Pro',
      description: 'Communication temps réel entre client et professionnel',
      status: 'pending',
      type: 'scenario',
      testPath: '/scenario/minitalk',
    },
    {
      id: '8',
      name: 'Kanban Restaurant',
      description: 'Gestion des commandes avec Kanban professionnel',
      status: 'pending',
      type: 'scenario',
      testPath: '/scenario/kanban',
    },
    {
      id: '5',
      name: 'Food Card Gallery',
      description: 'Galerie de menus foodcard, mobile-first',
      status: 'pending',
      type: 'scenario',
      testPath: '/scenario/foodcard',
    },
  ];

  const autoTests: AutoTest[] = [
    { id: 'a1', name: `${category}/health-check`, suite: category, status: 'passed', duration: 45 },
    { id: 'a2', name: `${category}/connection`, suite: category, status: 'passed', duration: 123 },
    { id: 'a3', name: `${category}/validation`, suite: category, status: 'failed', duration: 89 },
    { id: 'a4', name: `${category}/edge-cases`, suite: category, status: 'idle' },
  ];

  return { tests, autoTests };
}
