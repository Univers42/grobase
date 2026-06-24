/**
 * TypeBadge - Displays test type (automatic/manual)
 * Used for categorizing tests visually
 */

import {
  PerformanceIcon,
  UserIcon,
  MachineIcon,
  SettingsIcon,
  ScenariosIcon,
} from '../../icons/FlyIcons';
import './TypeBadge.css';

export type TestTypeVariant = 'automatic' | 'manual' | 'api' | 'database' | 'security' | 'scenario';

interface TypeBadgeProps {
  type: TestTypeVariant;
  size?: 'sm' | 'md';
}

const TYPE_CONFIG: Record<
  TestTypeVariant,
  { label: string; Icon: React.ComponentType<{ size?: number; className?: string }> }
> = {
  automatic: { label: 'Auto', Icon: PerformanceIcon },
  manual: { label: 'Manuel', Icon: UserIcon },
  api: { label: 'API', Icon: MachineIcon },
  database: { label: 'BDD', Icon: MachineIcon },
  security: { label: 'Sécurité', Icon: SettingsIcon },
  scenario: { label: 'Scénario', Icon: ScenariosIcon },
};

export function TypeBadge({ type, size = 'md' }: Readonly<TypeBadgeProps>) {
  const config = TYPE_CONFIG[type];
  const classes = buildClasses(type, size);
  const iconSize = size === 'sm' ? 10 : 12;

  return (
    <span className={classes}>
      <span className="type-badge-icon" aria-hidden="true">
        <config.Icon size={iconSize} />
      </span>
      <span className="type-badge-label">{config.label}</span>
    </span>
  );
}

function buildClasses(type: TestTypeVariant, size: string): string {
  return ['type-badge', `type-badge-${type}`, `type-badge-${size}`].join(' ');
}
