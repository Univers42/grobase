/**
 * ActivityItem - Single activity entry
 * Displays one activity with icon, title, and timestamp
 */

import type { Activity } from './types';
import './ActivityItem.css';

interface ActivityItemProps {
  activity: Activity;
}

export function ActivityItem({ activity }: Readonly<ActivityItemProps>) {
  const icon = getTypeIcon(activity.type);
  const severityClass = `activity-item--${activity.severity}`;

  return (
    <div className={`activity-item ${severityClass}`}>
      <span className="activity-item__icon">{icon}</span>
      <div className="activity-item__content">
        <span className="activity-item__title">{activity.title}</span>
        <span className="activity-item__desc">{activity.description}</span>
      </div>
      <span className="activity-item__time">{formatTime(activity.timestamp)}</span>
    </div>
  );
}

function getTypeIcon(type: Activity['type']): string {
  const icons: Record<Activity['type'], string> = {
    order: '🍽️',
    user: '👤',
    menu: '📋',
    system: '⚙️',
    staff: '👨‍🍳',
    alert: '🚨',
  };
  return icons[type];
}

function formatTime(date: Date): string {
  const now = new Date();
  const diff = now.getTime() - date.getTime();
  const minutes = Math.floor(diff / 60000);

  if (minutes < 1) return "À l'instant";
  if (minutes < 60) return `Il y a ${minutes}min`;

  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `Il y a ${hours}h`;

  return date.toLocaleDateString('fr-FR');
}
