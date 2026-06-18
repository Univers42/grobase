/**
 * Activity - Main activity monitoring component
 * Combines filters, list, and refresh controls
 */

import { useActivityData } from './useActivityData';
import { ActivityFilter } from './ActivityFilter';
import { ActivityList } from './ActivityList';
import './Activity.css';

export function Activity() {
  const { activities, loading, error, refresh, filterByType, activeFilters } = useActivityData();

  return (
    <div className="activity">
      <header className="activity__header">
        <h3 className="activity__title">Activité Récente</h3>
        <button className="activity__refresh" onClick={refresh} disabled={loading}>
          🔄 Rafraîchir
        </button>
      </header>

      <ActivityFilter activeFilters={activeFilters} onFilterChange={filterByType} />
      <ActivityList activities={activities} loading={loading} error={error} />
    </div>
  );
}
