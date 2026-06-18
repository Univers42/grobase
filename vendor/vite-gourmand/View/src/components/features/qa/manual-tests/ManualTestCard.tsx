/**
 * ManualTestCard - Card for manual test listing
 * Shows title, status, and quick actions
 */

import type { ManualTest } from './types';
import { StatusBadge, type BadgeStatus } from '../../../ui/badges/StatusBadge';
import { GhostButton } from '../../../ui/buttons/GhostButton';
import './ManualTestCard.css';

interface ManualTestCardProps {
  test: ManualTest;
  onSelect?: () => void;
}

export function ManualTestCard({ test, onSelect }: Readonly<ManualTestCardProps>) {
  const statusMap: Record<string, BadgeStatus> = {
    pending: 'pending',
    passed: 'success',
    failed: 'failed',
    blocked: 'idle',
  };

  return (
    <article className="manual-test-card">
      <header className="manual-test-card-header">
        <h3 className="manual-test-card-title">{test.title}</h3>
        <StatusBadge status={statusMap[test.result]} />
      </header>
      <p className="manual-test-card-description">{test.description}</p>
      <footer className="manual-test-card-footer">
        <span className="manual-test-card-steps">{test.steps.length} steps</span>
        <GhostButton onClick={onSelect}>Start Test →</GhostButton>
      </footer>
    </article>
  );
}
