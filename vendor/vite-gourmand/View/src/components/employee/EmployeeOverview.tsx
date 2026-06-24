/**
 * EmployeeOverview - Dashboard overview for employee role
 */

import './EmployeeWidgets.css';

export function EmployeeOverview() {
  return (
    <div className="employee-widget">
      <header className="widget-header">
        <div className="widget-header-content">
          <h2>👋 Bonjour, Jean</h2>
          <p className="widget-subtitle">Votre espace de travail</p>
        </div>
        <div className="shift-info">
          <div className="shift-icon">🕐</div>
          <div className="shift-details">
            <span className="shift-label">Service du jour</span>
            <span className="shift-time">11h30 - 15h00 / 18h00 - 22h30</span>
          </div>
        </div>
      </header>

      <div className="quick-stats-grid">
        <QuickStat icon="📋" label="À traiter" value="5" highlight />
        <QuickStat icon="✅" label="Livrées" value="12" />
        <QuickStat icon="⏱️" label="Temps moyen" value="8 min" />
        <QuickStat icon="⭐" label="Note du jour" value="4.9" />
      </div>

      <section className="widget-section">
        <div className="widget-section-header">
          <h3>🚨 Commandes urgentes</h3>
          <button className="btn btn-secondary btn-sm">Voir tout →</button>
        </div>
        <div className="urgent-orders-list">
          <UrgentOrder id="#1234" table="Table 5" time="5 min" items={3} />
          <UrgentOrder id="#1235" table="Table 2" time="3 min" items={2} />
        </div>
      </section>

      <section className="widget-section">
        <div className="widget-section-header">
          <h3>📝 Mes tâches du jour</h3>
          <button className="btn btn-secondary btn-sm">Tout voir →</button>
        </div>
        <div className="task-list">
          <TaskItem label="Mise en place salle" done priority="low" />
          <TaskItem label="Vérifier stocks" done={false} priority="medium" />
          <TaskItem label="Nettoyage fin de service" done={false} priority="low" />
        </div>
      </section>
    </div>
  );
}

interface QuickStatProps {
  icon: string;
  label: string;
  value: string;
  highlight?: boolean;
}

function QuickStat({ icon, label, value, highlight }: Readonly<QuickStatProps>) {
  return (
    <div className={`quick-stat ${highlight ? 'quick-stat--highlight' : ''}`}>
      <div className="quick-stat-icon">{icon}</div>
      <span className="quick-stat-value">{value}</span>
      <span className="quick-stat-label">{label}</span>
    </div>
  );
}

interface UrgentOrderProps {
  id: string;
  table: string;
  time: string;
  items: number;
}

function UrgentOrder({ id, table, time, items }: Readonly<UrgentOrderProps>) {
  return (
    <div className="urgent-order">
      <div className="urgent-order-icon">⚡</div>
      <div className="urgent-order-info">
        <span className="urgent-order-id">{id}</span>
        <div className="urgent-order-meta">
          <span>📍 {table}</span>
          <span>🍽️ {items} articles</span>
        </div>
      </div>
      <div className="urgent-order-time">⏱️ {time}</div>
      <button className="btn btn-warning btn-sm">Prendre en charge</button>
    </div>
  );
}

interface TaskItemProps {
  label: string;
  done: boolean;
  priority: 'high' | 'medium' | 'low';
}

function TaskItem({ label, done, priority }: Readonly<TaskItemProps>) {
  return (
    <div className={`task-item ${done ? 'task-item--done' : ''}`}>
      <div className="task-checkbox">{done ? '✓' : ''}</div>
      <span className="task-label">{label}</span>
      {!done && <span className={`task-priority task-priority--${priority}`}>{priority}</span>}
    </div>
  );
}
