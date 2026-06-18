/**
 * ActivityList - Displays a list of activities
 * Shows loading, empty, and error states
 */

import type { Activity } from './types';
import { ActivityItem } from './ActivityItem';
import './ActivityList.css';

interface ActivityListProps {
  activities: Activity[];
  loading: boolean;
  error: string | null;
}

export function ActivityList({ activities, loading, error }: Readonly<ActivityListProps>) {
  if (loading) {
    return <div className="activity-list__loading">Chargement...</div>;
  }

  if (error) {
    return <div className="activity-list__error">{error}</div>;
  }

  if (activities.length === 0) {
    return <div className="activity-list__empty">Aucune activité récente</div>;
  }

  return (
    <div className="activity-list">
      {activities.map((activity) => (
        <ActivityItem key={activity.id} activity={activity} />
      ))}
    </div>
  );
}
