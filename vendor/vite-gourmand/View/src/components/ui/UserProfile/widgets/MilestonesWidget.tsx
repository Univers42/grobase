/**
 * MilestonesWidget — List of profile milestones (achievements)
 * Visible: all roles
 */

import type { Milestone, ProfileWidgetProps } from '../types';
import { WidgetCard } from './WidgetCard';

export function MilestonesWidget({ profile }: Readonly<ProfileWidgetProps>) {
  return (
    <WidgetCard icon="🏆" title="Étapes & Succès" wide>
      <div className="up-milestones-list">
        {profile.milestones.length === 0 && (
          <div className="up-milestone-empty">Aucune étape atteinte pour l'instant.</div>
        )}
        {profile.milestones.map((m) => (
          <MilestoneItem key={m.id} milestone={m} />
        ))}
      </div>
    </WidgetCard>
  );
}

function MilestoneItem({ milestone }: Readonly<{ milestone: Milestone }>) {
  return (
    <div className={`up-milestone ${milestone.achieved ? 'up-milestone--achieved' : ''}`}>
      <span className="up-milestone-icon">{milestone.icon}</span>
      <span className="up-milestone-label">{milestone.label}</span>
      <span className="up-milestone-desc">{milestone.description}</span>
      {milestone.date && <span className="up-milestone-date">{formatDate(milestone.date)}</span>}
    </div>
  );
}

function formatDate(dateString?: string) {
  if (!dateString) return '';
  return new Date(dateString).toLocaleDateString('fr-FR', {
    day: 'numeric',
    month: 'long',
    year: 'numeric',
  });
}
