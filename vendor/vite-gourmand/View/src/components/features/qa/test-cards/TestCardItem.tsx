/**
 * TestCardItem - Individual test card display
 * Shows test name, status, type, and actions
 */

import { useNavigate } from 'react-router-dom';
import type { TestItem } from './types';
import { StatusBadge } from '../../../ui/badges/StatusBadge';
import { TypeBadge } from '../../../ui/badges/TypeBadge';
import { FlaskIcon, PlayIcon, EyeIcon } from '../../../icons/FlyIcons';
import './TestCardItem.css';

interface TestCardItemProps {
  test: TestItem;
  onRun?: () => void;
  onView?: () => void;
}

export function TestCardItem({ test, onRun, onView }: Readonly<TestCardItemProps>) {
  const navigate = useNavigate();
  const isRunning = test.status === 'running';

  const handleRunTest = () => {
    if (test.testPath) {
      navigate(test.testPath);
    } else if (onRun) {
      onRun();
    }
  };

  return (
    <article className="test-card-item">
      <header className="test-card-item-header">
        <h3 className="test-card-item-name">{test.name}</h3>
        <div className="test-card-item-badges">
          <StatusBadge status={test.status} />
          <TypeBadge type={test.type} />
        </div>
      </header>

      {test.description && <p className="test-card-item-description">{test.description}</p>}

      <footer className="test-card-item-footer">
        <span className="test-card-item-meta">{test.duration && `${test.duration}ms`}</span>
        <div className="test-card-item-actions">
          <button className="test-card-run-btn" onClick={handleRunTest} disabled={isRunning}>
            {test.testPath ? (
              <>
                <FlaskIcon size={14} />
                <span>Lancer le test</span>
              </>
            ) : (
              <>
                <PlayIcon size={14} />
                <span>Run</span>
              </>
            )}
          </button>
          {onView && (
            <button className="test-card-view-btn" onClick={onView} aria-label="View details">
              <EyeIcon size={16} />
            </button>
          )}
        </div>
      </footer>
    </article>
  );
}
