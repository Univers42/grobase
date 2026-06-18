/**
 * AdminStats - Statistics dashboard for admin role
 */

import './AdminWidgets.css';

export function AdminStats() {
  return (
    <div className="admin-widget">
      <header className="widget-header">
        <div className="widget-header-content">
          <h2>📈 Statistiques</h2>
          <p className="widget-subtitle">Analyse des performances</p>
        </div>
      </header>

      <div className="filter-tabs">
        <button className="filter-tab">Jour</button>
        <button className="filter-tab active">Semaine</button>
        <button className="filter-tab">Mois</button>
        <button className="filter-tab">Année</button>
      </div>

      <div className="stats-grid">
        <StatCard
          label="Chiffre d'affaires"
          value="8,450€"
          change="+15%"
          icon="💰"
          variant="success"
        />
        <StatCard label="Commandes" value="187" change="+8%" icon="📦" />
        <StatCard label="Panier moyen" value="45.20€" change="+3%" icon="🛒" />
        <StatCard label="Nouveaux clients" value="23" change="+12%" icon="👤" variant="warning" />
      </div>

      <section className="widget-section">
        <div className="widget-section-header">
          <h3>🏆 Top 5 des plats</h3>
        </div>
        <div className="ranking-list">
          <RankingItem rank={1} name="Pizza Margherita" count={45} maxCount={45} />
          <RankingItem rank={2} name="Burger Gourmet" count={38} maxCount={45} />
          <RankingItem rank={3} name="Salade César" count={32} maxCount={45} />
          <RankingItem rank={4} name="Pâtes Carbonara" count={28} maxCount={45} />
          <RankingItem rank={5} name="Tiramisu" count={24} maxCount={45} />
        </div>
      </section>
    </div>
  );
}

interface StatCardProps {
  label: string;
  value: string;
  change: string;
  icon: string;
  variant?: 'success' | 'warning' | 'error';
}

function StatCard({ label, value, change, icon, variant }: Readonly<StatCardProps>) {
  const isPositive = change.startsWith('+');
  const variantClass = variant ? `stat-card--${variant}` : '';
  return (
    <div className={`stat-card ${variantClass}`}>
      <div className="stat-icon">{icon}</div>
      <div className="stat-content">
        <span className="stat-value">{value}</span>
        <span className="stat-label">{label}</span>
        <span className={`stat-trend ${isPositive ? 'positive' : 'negative'}`}>{change}</span>
      </div>
    </div>
  );
}

function RankingItem({
  rank,
  name,
  count,
  maxCount,
}: Readonly<{
  rank: number;
  name: string;
  count: number;
  maxCount: number;
}>) {
  const percentage = (count / maxCount) * 100;
  return (
    <div className="ranking-item">
      <span className="ranking-position">{rank}</span>
      <span className="ranking-name">{name}</span>
      <div className="ranking-bar">
        <div className="ranking-bar-fill" style={{ width: `${percentage}%` }}></div>
      </div>
      <span className="ranking-count">{count} vendus</span>
    </div>
  );
}
