import { Outlet, NavLink, Navigate } from 'react-router-dom';
import useBaasAuth from '@/hooks/useBaasAuth';
import LoadingScreen from '@/components/ui/LoadingScreen';
import {
  LayoutDashboard, PawPrint, HeartPulse, Utensils,
  Ticket, Calendar, Users, MessageSquare, LogOut, TreePine,
} from 'lucide-react';

const sidebarLinks = [
  { to: '/admin',          icon: LayoutDashboard, label: 'Dashboard' },
  { to: '/admin/animals',  icon: PawPrint,        label: 'Animals' },
  { to: '/admin/health',   icon: HeartPulse,      label: 'Health' },
  { to: '/admin/feeding',  icon: Utensils,        label: 'Feeding' },
  { to: '/admin/tickets',  icon: Ticket,          label: 'Tickets' },
  { to: '/admin/events',   icon: Calendar,        label: 'Events' },
  { to: '/admin/staff',    icon: Users,           label: 'Staff' },
  { to: '/admin/messages', icon: MessageSquare,   label: 'Messages' },
];

const linkClass = ({ isActive }) =>
  `flex items-center gap-3 rounded-xl px-3 py-2.5 text-sm font-medium transition-all duration-200 ${
    isActive
      ? 'bg-forest text-ivory shadow-md'
      : 'text-charcoal/70 hover:bg-sand/60 hover:text-charcoal'
  }`;

export default function AdminLayout() {
  const { user, loading, signOut } = useBaasAuth();

  if (loading) return <LoadingScreen />;
  if (!user)   return <Navigate to="/admin/login" replace />;

  return (
    <div className="flex min-h-screen bg-ivory-warm">
      {/* Sidebar */}
      <aside className="fixed inset-y-0 left-0 z-40 flex w-64 flex-col border-r border-sand bg-white">
        {/* Logo */}
        <div className="flex h-16 items-center gap-2 border-b border-sand px-5">
          <TreePine className="h-6 w-6 text-forest" />
          <span className="font-display text-lg font-bold text-forest">Zoo Admin</span>
        </div>

        {/* Nav links */}
        <nav className="flex-1 space-y-1 overflow-y-auto px-3 py-4">
          {sidebarLinks.map((l) => (
            <NavLink key={l.to} to={l.to} end={l.to === '/admin'} className={linkClass}>
              <l.icon className="h-5 w-5 flex-shrink-0" />
              {l.label}
            </NavLink>
          ))}
        </nav>

        {/* User + sign-out */}
        <div className="border-t border-sand p-4">
          <div className="mb-3 text-xs text-charcoal/50">
            Signed in as <span className="font-semibold text-charcoal">{user?.email}</span>
          </div>
          <button
            onClick={signOut}
            className="flex w-full items-center gap-2 rounded-xl px-3 py-2.5 text-sm font-medium text-red-600 transition hover:bg-red-50"
          >
            <LogOut className="h-4 w-4" />
            Sign Out
          </button>
        </div>
      </aside>

      {/* Main content */}
      <div className="ml-64 flex-1">
        <header className="sticky top-0 z-30 flex h-16 items-center border-b border-sand bg-white/80 px-6 backdrop-blur-md">
          <h1 className="font-display text-xl font-semibold text-forest">
            Savanna Park — Staff Portal
          </h1>
        </header>

        <div className="p-6">
          <Outlet />
        </div>
      </div>
    </div>
  );
}
