/**
 * useActivityData Hook
 * Fetches and manages activity data - real data when available, mock for demo
 */

import { useState, useEffect, useCallback } from 'react';
import type { Activity, ActivityType } from './types';

const MOCK_ACTIVITIES: Activity[] = [
  {
    id: 'act-1',
    type: 'order',
    severity: 'success',
    title: 'Commande #1234 validée',
    description: 'Table 5 - 3 plats commandés',
    timestamp: new Date(Date.now() - 2 * 60 * 1000),
    user: 'client@example.com',
  },
  {
    id: 'act-2',
    type: 'user',
    severity: 'info',
    title: 'Nouvelle connexion',
    description: 'Serveur Marie connecté',
    timestamp: new Date(Date.now() - 5 * 60 * 1000),
    user: 'marie@vite-gourmand.fr',
  },
  {
    id: 'act-3',
    type: 'menu',
    severity: 'warning',
    title: 'Stock faible',
    description: 'Entrecôte - reste 3 portions',
    timestamp: new Date(Date.now() - 15 * 60 * 1000),
  },
  {
    id: 'act-4',
    type: 'system',
    severity: 'info',
    title: 'Déploiement réussi',
    description: 'Version 2.3.1 déployée sur production',
    timestamp: new Date(Date.now() - 30 * 60 * 1000),
  },
  {
    id: 'act-5',
    type: 'alert',
    severity: 'error',
    title: 'Erreur paiement',
    description: 'Échec transaction CB - Table 8',
    timestamp: new Date(Date.now() - 45 * 60 * 1000),
  },
];

interface UseActivityDataReturn {
  activities: Activity[];
  loading: boolean;
  error: string | null;
  refresh: () => void;
  filterByType: (types: ActivityType[]) => void;
  activeFilters: ActivityType[];
}

export function useActivityData(): UseActivityDataReturn {
  const [activities, setActivities] = useState<Activity[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [activeFilters, setActiveFilters] = useState<ActivityType[]>([]);

  const fetchActivities = useCallback(async () => {
    setLoading(true);
    setError(null);

    try {
      // Replace with real API call when the backend endpoint exists.
      // const response = await fetch('/api/activity');
      // const data = await response.json();

      // Simulate API delay
      await new Promise((resolve) => setTimeout(resolve, 300));
      setActivities(MOCK_ACTIVITIES);
    } catch {
      setError('Failed to load activities');
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    fetchActivities();
  }, [fetchActivities]);

  const filterByType = useCallback((types: ActivityType[]) => {
    setActiveFilters(types);
  }, []);

  const filteredActivities =
    activeFilters.length > 0
      ? activities.filter((a) => activeFilters.includes(a.type))
      : activities;

  return {
    activities: filteredActivities,
    loading,
    error,
    refresh: fetchActivities,
    filterByType,
    activeFilters,
  };
}
