import { useEffect, useState } from 'react';
import { motion } from 'framer-motion';
import {
  PawPrint, Ticket, Calendar, Users, TrendingUp,
  DollarSign, Eye, AlertTriangle,
} from 'lucide-react';
import { AreaChart, Area, XAxis, YAxis, CartesianGrid, Tooltip, ResponsiveContainer } from 'recharts';
import useBaasCollection from '@/hooks/useBaasCollection';
import useBaasRealtime from '@/hooks/useBaasRealtime';

// ── Stat card ─────────────────────────────────────────────────
function StatCard({ icon: Icon, label, value, color = 'text-forest', sub, delay = 0 }) {
  return (
    <motion.div
      initial={{ opacity: 0, y: 15 }}
      animate={{ opacity: 1, y: 0 }}
      transition={{ delay }}
      className="card p-5"
    >
      <div className="flex items-start justify-between">
        <div>
          <p className="text-xs font-medium uppercase tracking-wider text-charcoal/50">{label}</p>
          <p className={`mt-1 font-display text-3xl font-bold ${color}`}>{value}</p>
          {sub && <p className="mt-1 text-xs text-charcoal/40">{sub}</p>}
        </div>
        <div className="flex h-10 w-10 items-center justify-center rounded-xl bg-forest/10">
          <Icon className="h-5 w-5 text-forest" />
        </div>
      </div>
    </motion.div>
  );
}

export default function Dashboard() {
  const { data: animals }  = useBaasCollection('animals');
  const { data: events }   = useBaasCollection('events', { filters: { is_active: true } });
  const { data: messages }  = useBaasCollection('visitor_messages', { filters: { status: 'unread' } });
  const { data: stats }    = useBaasCollection('visitor_stats', { order: 'stat_date.desc', limit: 30 });
  const { data: tickets }  = useBaasCollection('tickets', { limit: 5, order: 'created_at.desc' });

  // Real-time: flash when a new ticket arrives
  const [ticketFlash, setTicketFlash] = useState(false);
  useBaasRealtime('tickets', 'insert', () => {
    setTicketFlash(true);
    setTimeout(() => setTicketFlash(false), 2000);
  });

  // Chart data
  const chartData = (stats || [])
    .slice()
    .reverse()
    .map((s) => ({
      date: new Date(s.stat_date).toLocaleDateString('en-GB', { day: '2-digit', month: 'short' }),
      visitors: s.total_visitors,
      revenue: Number(s.total_revenue),
    }));

  const totalRevenue = (stats || []).reduce((sum, s) => sum + Number(s.total_revenue), 0);

  return (
    <div className="space-y-8">
      <div>
        <h2 className="font-display text-2xl font-bold text-forest">Dashboard</h2>
        <p className="text-sm text-charcoal/50">Welcome back. Here's what's happening today.</p>
      </div>

      {/* KPI cards */}
      <div className="grid gap-4 sm:grid-cols-2 xl:grid-cols-4">
        <StatCard
          icon={PawPrint}
          label="Total Animals"
          value={animals?.length ?? '—'}
          delay={0}
        />
        <StatCard
          icon={Calendar}
          label="Active Events"
          value={events?.length ?? '—'}
          delay={0.05}
        />
        <StatCard
          icon={AlertTriangle}
          label="Unread Messages"
          value={messages?.length ?? '—'}
          color={messages?.length > 0 ? 'text-amber' : 'text-forest'}
          delay={0.1}
        />
        <StatCard
          icon={DollarSign}
          label="Revenue (30d)"
          value={`€${totalRevenue.toLocaleString('en', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`}
          delay={0.15}
        />
      </div>

      {/* Visitor chart */}
      {chartData.length > 0 && (
        <motion.div
          initial={{ opacity: 0 }}
          animate={{ opacity: 1 }}
          transition={{ delay: 0.2 }}
          className="card p-6"
        >
          <h3 className="mb-4 font-display text-lg font-bold text-forest">
            Visitors & Revenue — Last 30 Days
          </h3>
          <div className="h-72">
            <ResponsiveContainer width="100%" height="100%">
              <AreaChart data={chartData} margin={{ top: 5, right: 10, left: 0, bottom: 0 }}>
                <defs>
                  <linearGradient id="gVisitors" x1="0" y1="0" x2="0" y2="1">
                    <stop offset="5%" stopColor="#1a3a2a" stopOpacity={0.3} />
                    <stop offset="95%" stopColor="#1a3a2a" stopOpacity={0} />
                  </linearGradient>
                  <linearGradient id="gRevenue" x1="0" y1="0" x2="0" y2="1">
                    <stop offset="5%" stopColor="#c4702a" stopOpacity={0.3} />
                    <stop offset="95%" stopColor="#c4702a" stopOpacity={0} />
                  </linearGradient>
                </defs>
                <CartesianGrid strokeDasharray="3 3" stroke="#e8d5a3" />
                <XAxis dataKey="date" tick={{ fontSize: 11 }} stroke="#999" />
                <YAxis tick={{ fontSize: 11 }} stroke="#999" />
                <Tooltip
                  contentStyle={{
                    background: '#faf7f0',
                    border: '1px solid #e8d5a3',
                    borderRadius: 12,
                    fontSize: 12,
                  }}
                />
                <Area type="monotone" dataKey="visitors" stroke="#1a3a2a" fill="url(#gVisitors)" />
                <Area type="monotone" dataKey="revenue" stroke="#c4702a" fill="url(#gRevenue)" />
              </AreaChart>
            </ResponsiveContainer>
          </div>
        </motion.div>
      )}

      {/* Recent tickets */}
      <motion.div initial={{ opacity: 0 }} animate={{ opacity: 1 }} transition={{ delay: 0.3 }} className="card">
        <div className="flex items-center justify-between border-b border-sand px-6 py-4">
          <h3 className="font-display text-lg font-bold text-forest">Recent Tickets</h3>
          {ticketFlash && (
            <span className="animate-pulse rounded-full bg-green-100 px-3 py-1 text-xs font-bold text-green-700">
              New ticket!
            </span>
          )}
        </div>
        <div className="divide-y divide-sand">
          {tickets?.length ? (
            tickets.map((t) => (
              <div key={t.id} className="flex items-center justify-between px-6 py-3 text-sm">
                <div>
                  <p className="font-medium">{t.visitor_name}</p>
                  <p className="text-xs text-charcoal/40">
                    {t.visit_date} · {t.status}
                  </p>
                </div>
                <span className="font-medium text-forest">€{Number(t.total_eur).toFixed(2)}</span>
              </div>
            ))
          ) : (
            <p className="px-6 py-8 text-center text-sm text-charcoal/40">No tickets yet.</p>
          )}
        </div>
      </motion.div>
    </div>
  );
}
