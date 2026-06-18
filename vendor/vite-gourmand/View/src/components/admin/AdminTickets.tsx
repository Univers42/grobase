/**
 * AdminTickets — Support ticket management with Kanban & List views
 * Wired to GET/PUT /api/support endpoints
 */
import { useState, useEffect, useCallback, useMemo } from 'react';
import { apiRequest } from '../../services/api';

/* ── types ─────────────────────────────────────────────────── */

interface Ticket {
  id: number;
  ticket_number: string;
  category: string;
  subject: string;
  description?: string;
  status: string;
  priority: string;
  created_at: string;
  resolved_at?: string;
  closed_at?: string;
  User_SupportTicket_created_byToUser?: {
    id: number;
    first_name: string;
    last_name: string;
    email: string;
  } | null;
  User_SupportTicket_assigned_toToUser?: {
    id: number;
    first_name: string;
    last_name: string;
  } | null;
  TicketMessage?: { id: number; body: string; created_at: string }[];
}

interface Stats {
  open: number;
  inProgress: number;
  resolved: number;
  closed: number;
  total: number;
}

type ViewMode = 'kanban' | 'list';
type StatusFilter = 'all' | 'open' | 'in_progress' | 'resolved' | 'closed';

/* ── constants ────────────────────────────────────────────── */

const STATUS_META: Record<
  string,
  { label: string; color: string; bg: string; border: string; icon: string }
> = {
  open: {
    label: 'Ouvert',
    color: '#D4AF37',
    bg: 'rgba(212,175,55,.10)',
    border: 'rgba(212,175,55,.25)',
    icon: '🟡',
  },
  in_progress: {
    label: 'En cours',
    color: '#3B82F6',
    bg: 'rgba(59,130,246,.10)',
    border: 'rgba(59,130,246,.25)',
    icon: '🔵',
  },
  waiting_customer: {
    label: 'Attente client',
    color: '#F59E0B',
    bg: 'rgba(245,158,11,.10)',
    border: 'rgba(245,158,11,.25)',
    icon: '🟠',
  },
  resolved: {
    label: 'Résolu',
    color: '#556B2F',
    bg: 'rgba(85,107,47,.10)',
    border: 'rgba(85,107,47,.25)',
    icon: '🟢',
  },
  closed: {
    label: 'Fermé',
    color: '#6B7280',
    bg: 'rgba(107,114,128,.10)',
    border: 'rgba(107,114,128,.25)',
    icon: '⚫',
  },
};

const PRIORITY_META: Record<string, { label: string; color: string }> = {
  low: { label: 'Basse', color: '#9CA3AF' },
  normal: { label: 'Normale', color: '#3B82F6' },
  high: { label: 'Haute', color: '#F59E0B' },
  urgent: { label: 'Urgente', color: '#EF4444' },
};

const CATEGORY_META: Record<string, { label: string; emoji: string }> = {
  order: { label: 'Commande', emoji: '📦' },
  delivery: { label: 'Livraison', emoji: '🚚' },
  payment: { label: 'Paiement', emoji: '💳' },
  account: { label: 'Compte', emoji: '👤' },
  menu: { label: 'Menu', emoji: '🍽️' },
  other: { label: 'Autre', emoji: '❓' },
};

const KANBAN_COLUMNS = ['open', 'in_progress', 'resolved', 'closed'] as const;

/* ── component ────────────────────────────────────────────── */

export function AdminTickets() {
  const [tickets, setTickets] = useState<Ticket[]>([]);
  const [stats, setStats] = useState<Stats | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [viewMode, setViewMode] = useState<ViewMode>('kanban');
  const [statusFilter, setStatusFilter] = useState<StatusFilter>('all');
  const [selectedTicket, setSelectedTicket] = useState<Ticket | null>(null);

  /* ── data fetching ───────────────────────────────────────── */

  const fetchTickets = useCallback(async () => {
    try {
      const [ticketsRes, statsRes] = await Promise.all([
        apiRequest<{ data: Ticket[] }>('/api/support'),
        apiRequest<{ data: Stats }>('/api/support/stats'),
      ]);
      setTickets(Array.isArray(ticketsRes) ? ticketsRes : (ticketsRes.data ?? []));
      setStats('data' in statsRes ? statsRes.data : statsRes);
      setError(null);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Erreur de chargement');
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    fetchTickets();
  }, [fetchTickets]);

  /* ── actions ────────────────────────────────────────────── */

  const updateStatus = async (id: number, status: string) => {
    try {
      await apiRequest(`/api/support/${id}`, { method: 'PUT', body: { status } });
      await fetchTickets();
      if (selectedTicket?.id === id) setSelectedTicket(null);
    } catch (err) {
      console.error('Update failed', err);
    }
  };

  const takeTicket = async (id: number) => {
    try {
      await apiRequest(`/api/support/${id}/take`, { method: 'POST' });
      await fetchTickets();
    } catch (err) {
      console.error('Take failed', err);
    }
  };

  /* ── filtered tickets ───────────────────────────────────── */

  const filteredTickets = useMemo(() => {
    if (statusFilter === 'all') return tickets;
    return tickets.filter((t) => t.status === statusFilter);
  }, [tickets, statusFilter]);

  /* ── render ─────────────────────────────────────────────── */

  if (loading) return <LoadingSkeleton />;
  if (error) return <ErrorBanner message={error} onRetry={fetchTickets} />;

  return (
    <div style={{ fontFamily: "'Segoe UI', sans-serif" }}>
      {/* Header bar */}
      <div
        style={{
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'space-between',
          marginBottom: 24,
          flexWrap: 'wrap',
          gap: 12,
        }}
      >
        <div>
          <h2 style={{ margin: 0, fontSize: 22, fontWeight: 800, color: '#1A1A1A' }}>
            🎫 Support & Tickets
          </h2>
          <p style={{ margin: '4px 0 0', fontSize: 13, color: '#888' }}>
            {stats ? `${stats.total} ticket(s) — ${stats.open} ouvert(s)` : ''}
          </p>
        </div>
        <div style={{ display: 'flex', gap: 8 }}>
          <ViewToggle mode={viewMode} onChange={setViewMode} />
          <button onClick={fetchTickets} style={refreshBtnStyle} title="Rafraîchir">
            🔄
          </button>
        </div>
      </div>

      {/* Stats cards */}
      {stats && <StatsBar stats={stats} />}

      {/* Filter tabs (list view) */}
      {viewMode === 'list' && (
        <div style={{ display: 'flex', gap: 6, marginBottom: 16, flexWrap: 'wrap' }}>
          {(['all', 'open', 'in_progress', 'resolved', 'closed'] as StatusFilter[]).map((s) => (
            <button
              key={s}
              onClick={() => setStatusFilter(s)}
              style={{
                padding: '6px 14px',
                borderRadius: 20,
                fontSize: 12,
                fontWeight: 600,
                cursor: 'pointer',
                border: '1px solid',
                borderColor: statusFilter === s ? '#722F37' : '#e5e7eb',
                background: statusFilter === s ? '#722F37' : 'white',
                color: statusFilter === s ? 'white' : '#555',
                transition: 'all .15s',
              }}
            >
              {s === 'all' ? 'Tous' : STATUS_META[s]?.label || s}
              {s !== 'all' && ` (${tickets.filter((t) => t.status === s).length})`}
            </button>
          ))}
        </div>
      )}

      {/* Main view */}
      {viewMode === 'kanban' ? (
        <KanbanBoard
          tickets={tickets}
          onUpdateStatus={updateStatus}
          onTake={takeTicket}
          onSelect={setSelectedTicket}
        />
      ) : (
        <ListView
          tickets={filteredTickets}
          onUpdateStatus={updateStatus}
          onTake={takeTicket}
          onSelect={setSelectedTicket}
        />
      )}

      {/* Ticket detail modal */}
      {selectedTicket && (
        <TicketDetail
          ticket={selectedTicket}
          onClose={() => setSelectedTicket(null)}
          onUpdateStatus={updateStatus}
          onTake={takeTicket}
        />
      )}
    </div>
  );
}

/* ═══════════════════════════════════════════════════════════
   Sub-components
   ═══════════════════════════════════════════════════════════ */

function StatsBar({ stats }: Readonly<{ stats: Stats }>) {
  const items = [
    { label: 'Ouverts', value: stats.open, color: '#D4AF37', icon: '🟡' },
    { label: 'En cours', value: stats.inProgress, color: '#3B82F6', icon: '🔵' },
    { label: 'Résolus', value: stats.resolved, color: '#556B2F', icon: '🟢' },
    { label: 'Fermés', value: stats.closed, color: '#6B7280', icon: '⚫' },
  ];
  return (
    <div
      style={{
        display: 'grid',
        gridTemplateColumns: 'repeat(auto-fit, minmax(130px, 1fr))',
        gap: 10,
        marginBottom: 20,
      }}
    >
      {items.map((i) => (
        <div
          key={i.label}
          style={{
            background: 'white',
            borderRadius: 12,
            padding: '14px 16px',
            border: '1px solid #f0f0f0',
            boxShadow: '0 1px 3px rgba(0,0,0,.04)',
          }}
        >
          <div style={{ fontSize: 12, color: '#888', marginBottom: 4 }}>
            {i.icon} {i.label}
          </div>
          <div style={{ fontSize: 26, fontWeight: 800, color: i.color }}>{i.value}</div>
        </div>
      ))}
    </div>
  );
}

function ViewToggle({
  mode,
  onChange,
}: Readonly<{ mode: ViewMode; onChange: (m: ViewMode) => void }>) {
  return (
    <div
      style={{ display: 'flex', borderRadius: 8, overflow: 'hidden', border: '1px solid #e5e7eb' }}
    >
      {(['kanban', 'list'] as ViewMode[]).map((m) => (
        <button
          key={m}
          onClick={() => onChange(m)}
          style={{
            padding: '6px 14px',
            fontSize: 12,
            fontWeight: 600,
            cursor: 'pointer',
            border: 'none',
            background: mode === m ? '#722F37' : 'white',
            color: mode === m ? 'white' : '#555',
          }}
        >
          {m === 'kanban' ? '⬜ Kanban' : '☰ Liste'}
        </button>
      ))}
    </div>
  );
}

/* ── Kanban Board ────────────────────────────────────────── */

function KanbanBoard({
  tickets,
  onUpdateStatus,
  onTake,
  onSelect,
}: Readonly<{
  tickets: Ticket[];
  onUpdateStatus: (id: number, status: string) => void;
  onTake: (id: number) => void;
  onSelect: (t: Ticket) => void;
}>) {
  return (
    <div
      style={{
        display: 'grid',
        gridTemplateColumns: `repeat(${KANBAN_COLUMNS.length}, 1fr)`,
        gap: 12,
        minHeight: 400,
      }}
    >
      {KANBAN_COLUMNS.map((status) => {
        const meta = STATUS_META[status];
        const col = tickets.filter((t) => t.status === status);
        return (
          <div
            key={status}
            style={{
              background: '#f9fafb',
              borderRadius: 14,
              padding: 12,
              border: `1px solid ${meta.border}`,
              display: 'flex',
              flexDirection: 'column',
            }}
          >
            {/* Column header */}
            <div
              style={{
                display: 'flex',
                alignItems: 'center',
                justifyContent: 'space-between',
                marginBottom: 10,
                paddingBottom: 8,
                borderBottom: `2px solid ${meta.color}`,
              }}
            >
              <span style={{ fontWeight: 700, fontSize: 13, color: meta.color }}>
                {meta.icon} {meta.label}
              </span>
              <span
                style={{
                  background: meta.bg,
                  color: meta.color,
                  borderRadius: 10,
                  padding: '2px 8px',
                  fontSize: 11,
                  fontWeight: 700,
                }}
              >
                {col.length}
              </span>
            </div>

            {/* Cards */}
            <div
              style={{
                flex: 1,
                overflowY: 'auto',
                display: 'flex',
                flexDirection: 'column',
                gap: 8,
              }}
            >
              {col.length === 0 && (
                <div
                  style={{ textAlign: 'center', padding: '30px 10px', color: '#bbb', fontSize: 12 }}
                >
                  Aucun ticket
                </div>
              )}
              {col.map((ticket) => (
                <TicketCard
                  key={ticket.id}
                  ticket={ticket}
                  onSelect={onSelect}
                  onTake={onTake}
                  onUpdateStatus={onUpdateStatus}
                />
              ))}
            </div>
          </div>
        );
      })}
    </div>
  );
}

/* ── Ticket Card ─────────────────────────────────────────── */

function TicketCard({
  ticket,
  onSelect,
  onTake,
  onUpdateStatus,
}: Readonly<{
  ticket: Ticket;
  onSelect: (t: Ticket) => void;
  onTake: (id: number) => void;
  onUpdateStatus: (id: number, status: string) => void;
}>) {
  const prio = PRIORITY_META[ticket.priority] || PRIORITY_META.normal;
  const cat = CATEGORY_META[ticket.category] || CATEGORY_META.other;
  const creator = ticket.User_SupportTicket_created_byToUser;
  const assignee = ticket.User_SupportTicket_assigned_toToUser;
  const date = new Date(ticket.created_at).toLocaleDateString('fr-FR', {
    day: '2-digit',
    month: 'short',
  });

  return (
    <article
      style={{
        background: 'white',
        borderRadius: 10,
        padding: 12,
        border: '1px solid #e8e8e8',
        boxShadow: '0 1px 3px rgba(0,0,0,.04)',
        transition: 'box-shadow .15s, transform .15s',
        textAlign: 'left',
        width: '100%',
      }}
      onMouseEnter={(e) => {
        e.currentTarget.style.boxShadow = '0 4px 12px rgba(0,0,0,.08)';
        e.currentTarget.style.transform = 'translateY(-1px)';
      }}
      onMouseLeave={(e) => {
        e.currentTarget.style.boxShadow = '0 1px 3px rgba(0,0,0,.04)';
        e.currentTarget.style.transform = 'none';
      }}
    >
      {/* Top line: ticket # + priority */}
      <div
        style={{
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'space-between',
          marginBottom: 6,
        }}
      >
        <span style={{ fontSize: 10, color: '#999', fontWeight: 600, fontFamily: 'monospace' }}>
          {ticket.ticket_number}
        </span>
        <span
          style={{
            fontSize: 9,
            fontWeight: 700,
            color: prio.color,
            background: `${prio.color}18`,
            padding: '2px 6px',
            borderRadius: 6,
            textTransform: 'uppercase',
            letterSpacing: '0.5px',
          }}
        >
          {prio.label}
        </span>
      </div>

      {/* Subject */}
      <button
        type="button"
        onClick={() => onSelect(ticket)}
        style={{
          margin: '0 0 8px',
          padding: 0,
          border: 'none',
          background: 'transparent',
          fontSize: 13,
          fontWeight: 600,
          color: '#1A1A1A',
          lineHeight: 1.35,
          textAlign: 'left',
          cursor: 'pointer',
        }}
      >
        {ticket.subject}
      </button>

      {/* Meta: category + date */}
      <div
        style={{
          display: 'flex',
          alignItems: 'center',
          gap: 8,
          fontSize: 11,
          color: '#999',
          marginBottom: 8,
        }}
      >
        <span>
          {cat.emoji} {cat.label}
        </span>
        <span>·</span>
        <span>{date}</span>
      </div>

      {/* Creator + assignee */}
      <div
        style={{
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'space-between',
          fontSize: 11,
        }}
      >
        <span style={{ color: '#777' }}>
          {creator ? `${creator.first_name} ${creator.last_name?.[0] || ''}.` : '—'}
        </span>
        {assignee && (
          <span style={{ color: '#3B82F6', fontWeight: 600, fontSize: 10 }}>
            → {assignee.first_name}
          </span>
        )}
        {!assignee && ticket.status === 'open' && (
          <button
            onClick={(e) => {
              e.stopPropagation();
              onTake(ticket.id);
            }}
            style={{
              fontSize: 10,
              fontWeight: 700,
              color: '#722F37',
              background: 'rgba(114,47,55,.08)',
              border: 'none',
              borderRadius: 6,
              padding: '3px 8px',
              cursor: 'pointer',
            }}
          >
            Prendre
          </button>
        )}
      </div>

      {/* Quick actions */}
      {ticket.status !== 'closed' && (
        <div
          style={{
            display: 'flex',
            gap: 4,
            marginTop: 8,
            borderTop: '1px solid #f3f3f3',
            paddingTop: 8,
          }}
        >
          {ticket.status === 'open' && (
            <MiniBtn
              label="En cours"
              color="#3B82F6"
              onClick={(e) => {
                e.stopPropagation();
                onUpdateStatus(ticket.id, 'in_progress');
              }}
            />
          )}
          {(ticket.status === 'open' || ticket.status === 'in_progress') && (
            <MiniBtn
              label="Résoudre"
              color="#556B2F"
              onClick={(e) => {
                e.stopPropagation();
                onUpdateStatus(ticket.id, 'resolved');
              }}
            />
          )}
          {ticket.status === 'resolved' && (
            <MiniBtn
              label="Fermer"
              color="#6B7280"
              onClick={(e) => {
                e.stopPropagation();
                onUpdateStatus(ticket.id, 'closed');
              }}
            />
          )}
        </div>
      )}
    </article>
  );
}

function MiniBtn({
  label,
  color,
  onClick,
}: Readonly<{ label: string; color: string; onClick: (e: React.MouseEvent) => void }>) {
  return (
    <button
      onClick={onClick}
      style={{
        fontSize: 10,
        fontWeight: 600,
        color,
        background: `${color}12`,
        border: `1px solid ${color}30`,
        borderRadius: 6,
        padding: '3px 8px',
        cursor: 'pointer',
        transition: 'background .15s',
      }}
    >
      {label}
    </button>
  );
}

/* ── List View ───────────────────────────────────────────── */

function ListView({
  tickets,
  onUpdateStatus,
  onTake,
  onSelect,
}: Readonly<{
  tickets: Ticket[];
  onUpdateStatus: (id: number, status: string) => void;
  onTake: (id: number) => void;
  onSelect: (t: Ticket) => void;
}>) {
  if (tickets.length === 0) {
    return (
      <div style={{ textAlign: 'center', padding: 40, color: '#bbb' }}>Aucun ticket trouvé.</div>
    );
  }
  return (
    <div
      style={{
        background: 'white',
        borderRadius: 14,
        overflow: 'hidden',
        border: '1px solid #f0f0f0',
      }}
    >
      <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 13 }}>
        <thead>
          <tr style={{ background: '#fafafa', borderBottom: '1px solid #f0f0f0' }}>
            <th style={thStyle}>Ticket</th>
            <th style={thStyle}>Sujet</th>
            <th style={thStyle}>Statut</th>
            <th style={thStyle}>Priorité</th>
            <th style={thStyle}>Catégorie</th>
            <th style={thStyle}>Date</th>
            <th style={thStyle}>Actions</th>
          </tr>
        </thead>
        <tbody>
          {tickets.map((t) => {
            const st = STATUS_META[t.status] || STATUS_META.open;
            const pr = PRIORITY_META[t.priority] || PRIORITY_META.normal;
            const cat = CATEGORY_META[t.category] || CATEGORY_META.other;
            return (
              <tr
                key={t.id}
                onClick={() => onSelect(t)}
                style={{
                  borderBottom: '1px solid #f5f5f5',
                  cursor: 'pointer',
                  transition: 'background .1s',
                }}
                onMouseEnter={(e) => {
                  e.currentTarget.style.background = '#fefaf6';
                }}
                onMouseLeave={(e) => {
                  e.currentTarget.style.background = 'transparent';
                }}
              >
                <td
                  style={{
                    ...tdStyle,
                    fontFamily: 'monospace',
                    fontWeight: 600,
                    fontSize: 11,
                    color: '#999',
                  }}
                >
                  {t.ticket_number}
                </td>
                <td
                  style={{
                    ...tdStyle,
                    fontWeight: 600,
                    maxWidth: 250,
                    overflow: 'hidden',
                    textOverflow: 'ellipsis',
                    whiteSpace: 'nowrap',
                  }}
                >
                  {t.subject}
                </td>
                <td style={tdStyle}>
                  <span
                    style={{
                      display: 'inline-flex',
                      alignItems: 'center',
                      gap: 4,
                      background: st.bg,
                      color: st.color,
                      fontWeight: 700,
                      fontSize: 11,
                      padding: '3px 10px',
                      borderRadius: 10,
                      border: `1px solid ${st.border}`,
                    }}
                  >
                    {st.icon} {st.label}
                  </span>
                </td>
                <td style={tdStyle}>
                  <span style={{ color: pr.color, fontWeight: 600, fontSize: 11 }}>{pr.label}</span>
                </td>
                <td style={tdStyle}>
                  <span style={{ fontSize: 11 }}>
                    {cat.emoji} {cat.label}
                  </span>
                </td>
                <td style={{ ...tdStyle, fontSize: 11, color: '#888' }}>
                  {new Date(t.created_at).toLocaleDateString('fr-FR')}
                </td>
                <td style={tdStyle}>
                  <div style={{ display: 'flex', gap: 4 }}>
                    {t.status === 'open' && !t.User_SupportTicket_assigned_toToUser && (
                      <MiniBtn
                        label="Prendre"
                        color="#722F37"
                        onClick={(e) => {
                          e.stopPropagation();
                          onTake(t.id);
                        }}
                      />
                    )}
                    {t.status === 'open' && (
                      <MiniBtn
                        label="En cours"
                        color="#3B82F6"
                        onClick={(e) => {
                          e.stopPropagation();
                          onUpdateStatus(t.id, 'in_progress');
                        }}
                      />
                    )}
                    {t.status === 'in_progress' && (
                      <MiniBtn
                        label="Résoudre"
                        color="#556B2F"
                        onClick={(e) => {
                          e.stopPropagation();
                          onUpdateStatus(t.id, 'resolved');
                        }}
                      />
                    )}
                    {t.status === 'resolved' && (
                      <MiniBtn
                        label="Fermer"
                        color="#6B7280"
                        onClick={(e) => {
                          e.stopPropagation();
                          onUpdateStatus(t.id, 'closed');
                        }}
                      />
                    )}
                  </div>
                </td>
              </tr>
            );
          })}
        </tbody>
      </table>
    </div>
  );
}

/* ── Ticket Detail Modal ─────────────────────────────────── */

function TicketDetail({
  ticket,
  onClose,
  onUpdateStatus,
  onTake,
}: Readonly<{
  ticket: Ticket;
  onClose: () => void;
  onUpdateStatus: (id: number, status: string) => void;
  onTake: (id: number) => void;
}>) {
  const st = STATUS_META[ticket.status] || STATUS_META.open;
  const pr = PRIORITY_META[ticket.priority] || PRIORITY_META.normal;
  const cat = CATEGORY_META[ticket.category] || CATEGORY_META.other;
  const creator = ticket.User_SupportTicket_created_byToUser;
  const assignee = ticket.User_SupportTicket_assigned_toToUser;

  return (
    <dialog
      onCancel={onClose}
      aria-label={`Ticket ${ticket.ticket_number}`}
      open
      style={{
        position: 'fixed',
        inset: 0,
        background: 'rgba(0,0,0,.45)',
        zIndex: 9999,
        border: 0,
        color: 'inherit',
        margin: 0,
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
        padding: 20,
      }}
    >
      <div
        style={{
          background: 'white',
          borderRadius: 20,
          maxWidth: 560,
          width: '100%',
          maxHeight: '85vh',
          overflow: 'auto',
          boxShadow: '0 20px 60px rgba(0,0,0,.2)',
        }}
      >
        {/* Header */}
        <div
          style={{
            background: 'linear-gradient(135deg, #722F37, #8B3A42)',
            padding: '20px 24px',
            borderRadius: '20px 20px 0 0',
            color: 'white',
          }}
        >
          <div
            style={{
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'space-between',
              marginBottom: 6,
            }}
          >
            <span style={{ fontFamily: 'monospace', fontSize: 12, opacity: 0.7 }}>
              {ticket.ticket_number}
            </span>
            <button
              onClick={onClose}
              aria-label="Fermer le ticket"
              style={{
                background: 'rgba(255,255,255,.15)',
                border: 'none',
                borderRadius: 8,
                color: 'white',
                padding: '4px 10px',
                cursor: 'pointer',
                fontSize: 14,
              }}
            >
              ✕
            </button>
          </div>
          <h3 style={{ margin: '0 0 8px', fontSize: 18, fontWeight: 700 }}>{ticket.subject}</h3>
          <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
            <span
              style={{
                background: st.bg,
                color: st.color,
                fontSize: 11,
                fontWeight: 700,
                padding: '3px 10px',
                borderRadius: 8,
              }}
            >
              {st.icon} {st.label}
            </span>
            <span
              style={{
                background: `${pr.color}20`,
                color: pr.color,
                fontSize: 11,
                fontWeight: 700,
                padding: '3px 10px',
                borderRadius: 8,
              }}
            >
              {pr.label}
            </span>
            <span
              style={{
                background: 'rgba(255,255,255,.15)',
                color: 'white',
                fontSize: 11,
                fontWeight: 600,
                padding: '3px 10px',
                borderRadius: 8,
              }}
            >
              {cat.emoji} {cat.label}
            </span>
          </div>
        </div>

        {/* Body */}
        <div style={{ padding: 24 }}>
          {/* Description */}
          {ticket.description && (
            <div style={{ marginBottom: 20 }}>
              <h4
                style={{
                  margin: '0 0 8px',
                  fontSize: 13,
                  fontWeight: 700,
                  color: '#722F37',
                  textTransform: 'uppercase',
                  letterSpacing: 1,
                }}
              >
                Description
              </h4>
              <p
                style={{
                  margin: 0,
                  fontSize: 14,
                  lineHeight: 1.7,
                  color: '#444',
                  whiteSpace: 'pre-wrap',
                  background: '#f9fafb',
                  padding: 14,
                  borderRadius: 10,
                }}
              >
                {ticket.description}
              </p>
            </div>
          )}

          {/* Info grid */}
          <div
            style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12, marginBottom: 20 }}
          >
            <InfoCell
              label="Créé par"
              value={
                creator ? `${creator.first_name} ${creator.last_name}` : 'Visiteur (non connecté)'
              }
              sub={creator?.email}
            />
            <InfoCell
              label="Assigné à"
              value={assignee ? `${assignee.first_name} ${assignee.last_name}` : 'Non assigné'}
            />
            <InfoCell label="Créé le" value={new Date(ticket.created_at).toLocaleString('fr-FR')} />
            <InfoCell
              label="Résolu le"
              value={
                ticket.resolved_at ? new Date(ticket.resolved_at).toLocaleString('fr-FR') : '—'
              }
            />
          </div>

          {/* Messages */}
          {ticket.TicketMessage && ticket.TicketMessage.length > 0 && (
            <div style={{ marginBottom: 20 }}>
              <h4
                style={{
                  margin: '0 0 8px',
                  fontSize: 13,
                  fontWeight: 700,
                  color: '#722F37',
                  textTransform: 'uppercase',
                  letterSpacing: 1,
                }}
              >
                Messages ({ticket.TicketMessage.length})
              </h4>
              <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
                {ticket.TicketMessage.map((msg) => (
                  <div
                    key={msg.id}
                    style={{
                      background: '#f9fafb',
                      borderRadius: 10,
                      padding: 12,
                      fontSize: 13,
                      color: '#444',
                      lineHeight: 1.6,
                    }}
                  >
                    {msg.body}
                    <div style={{ marginTop: 6, fontSize: 10, color: '#aaa' }}>
                      {new Date(msg.created_at).toLocaleString('fr-FR')}
                    </div>
                  </div>
                ))}
              </div>
            </div>
          )}

          {/* Actions */}
          <div
            style={{
              display: 'flex',
              gap: 8,
              flexWrap: 'wrap',
              borderTop: '1px solid #f0f0f0',
              paddingTop: 16,
            }}
          >
            {!assignee && ticket.status === 'open' && (
              <ActionBtn
                label="🙋 Prendre en charge"
                color="#722F37"
                onClick={() => onTake(ticket.id)}
              />
            )}
            {ticket.status === 'open' && (
              <ActionBtn
                label="🔵 Passer en cours"
                color="#3B82F6"
                onClick={() => onUpdateStatus(ticket.id, 'in_progress')}
              />
            )}
            {(ticket.status === 'open' || ticket.status === 'in_progress') && (
              <ActionBtn
                label="🟢 Marquer résolu"
                color="#556B2F"
                onClick={() => onUpdateStatus(ticket.id, 'resolved')}
              />
            )}
            {ticket.status === 'resolved' && (
              <ActionBtn
                label="⚫ Fermer"
                color="#6B7280"
                onClick={() => onUpdateStatus(ticket.id, 'closed')}
              />
            )}
          </div>
        </div>
      </div>
    </dialog>
  );
}

function InfoCell({ label, value, sub }: Readonly<{ label: string; value: string; sub?: string }>) {
  return (
    <div style={{ background: '#fafafa', borderRadius: 10, padding: 12 }}>
      <div
        style={{
          fontSize: 10,
          color: '#999',
          textTransform: 'uppercase',
          letterSpacing: 1,
          fontWeight: 600,
          marginBottom: 4,
        }}
      >
        {label}
      </div>
      <div style={{ fontSize: 13, fontWeight: 600, color: '#1A1A1A' }}>{value}</div>
      {sub && <div style={{ fontSize: 11, color: '#888', marginTop: 2 }}>{sub}</div>}
    </div>
  );
}

function ActionBtn({
  label,
  color,
  onClick,
}: Readonly<{ label: string; color: string; onClick: () => void }>) {
  return (
    <button
      onClick={onClick}
      style={{
        padding: '8px 16px',
        borderRadius: 8,
        fontSize: 12,
        fontWeight: 700,
        cursor: 'pointer',
        border: `1px solid ${color}40`,
        background: `${color}10`,
        color,
        transition: 'all .15s',
      }}
      onMouseEnter={(e) => {
        e.currentTarget.style.background = `${color}20`;
      }}
      onMouseLeave={(e) => {
        e.currentTarget.style.background = `${color}10`;
      }}
    >
      {label}
    </button>
  );
}

/* ── Skeleton & Error ────────────────────────────────────── */

function LoadingSkeleton() {
  return (
    <div style={{ padding: 20 }}>
      <div style={{ display: 'flex', gap: 10, marginBottom: 20 }}>
        {[1, 2, 3, 4].map((i) => (
          <div
            key={i}
            style={{
              width: '25%',
              height: 70,
              background: '#f3f4f6',
              borderRadius: 12,
              animation: 'pulse 1.5s infinite',
            }}
          />
        ))}
      </div>
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 12 }}>
        {[1, 2, 3, 4].map((i) => (
          <div
            key={i}
            style={{
              height: 300,
              background: '#f9fafb',
              borderRadius: 14,
              border: '1px solid #eee',
            }}
          />
        ))}
      </div>
    </div>
  );
}

function ErrorBanner({ message, onRetry }: Readonly<{ message: string; onRetry: () => void }>) {
  return (
    <div
      style={{
        background: '#FEF2F2',
        border: '1px solid #FECACA',
        borderRadius: 12,
        padding: 20,
        display: 'flex',
        alignItems: 'center',
        gap: 12,
      }}
    >
      <span style={{ fontSize: 24 }}>⚠️</span>
      <div style={{ flex: 1 }}>
        <p style={{ margin: 0, fontWeight: 700, color: '#991B1B', fontSize: 14 }}>
          Erreur de chargement
        </p>
        <p style={{ margin: '4px 0 0', color: '#B91C1C', fontSize: 12 }}>{message}</p>
      </div>
      <button
        onClick={onRetry}
        style={{
          padding: '8px 16px',
          borderRadius: 8,
          background: '#722F37',
          color: 'white',
          border: 'none',
          cursor: 'pointer',
          fontWeight: 600,
          fontSize: 12,
        }}
      >
        Réessayer
      </button>
    </div>
  );
}

/* ── table styles ─────────────────────────────────────────── */

const thStyle: React.CSSProperties = {
  textAlign: 'left',
  padding: '10px 14px',
  fontSize: 11,
  fontWeight: 700,
  color: '#888',
  textTransform: 'uppercase',
  letterSpacing: '0.5px',
};

const tdStyle: React.CSSProperties = {
  padding: '12px 14px',
  verticalAlign: 'middle',
};

const refreshBtnStyle: React.CSSProperties = {
  padding: '6px 12px',
  borderRadius: 8,
  border: '1px solid #e5e7eb',
  background: 'white',
  cursor: 'pointer',
  fontSize: 14,
};
