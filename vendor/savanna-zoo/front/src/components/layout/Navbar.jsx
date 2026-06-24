import { useState } from 'react';
import { Link, NavLink, useNavigate } from 'react-router-dom';
import { motion, AnimatePresence } from 'framer-motion';
import { Menu, X, TreePine, LogOut, User } from 'lucide-react';
import useBaasAuth from '@/hooks/useBaasAuth';

const publicLinks = [
  { to: '/',        label: 'Home' },
  { to: '/animals', label: 'Animals' },
  { to: '/events',  label: 'Events' },
  { to: '/tickets', label: 'Tickets' },
  { to: '/contact', label: 'Contact' },
];

const visitorLinks = [
  { to: '/my-tickets', label: 'My Tickets' },
  { to: '/journal',    label: 'Journal' },
];

const navLinkClass = ({ isActive }) =>
  `relative px-1 py-2 text-sm font-medium transition-colors duration-200 ${
    isActive ? 'text-amber' : 'text-ivory/80 hover:text-ivory'
  }`;

export default function Navbar() {
  const [open, setOpen] = useState(false);
  const { user, role, signOut } = useBaasAuth();
  const nav = useNavigate();

  // Staff (admin/zookeeper/vet/reception) use the Staff Portal, not the
  // visitor account menu; everyone else who is signed in is a visitor.
  const isStaff = ['admin', 'zookeeper', 'vet', 'reception'].includes(role);
  const isVisitor = Boolean(user) && !isStaff;
  const links = isVisitor ? [...publicLinks, ...visitorLinks] : publicLinks;
  const name = user?.user_metadata?.full_name || user?.email?.split('@')[0];

  const handleSignOut = async () => {
    await signOut();
    setOpen(false);
    nav('/');
  };

  return (
    <nav className="fixed inset-x-0 top-0 z-50 glass bg-forest/90 backdrop-blur-lg border-b border-white/10">
      <div className="mx-auto flex h-16 max-w-7xl items-center justify-between px-4 sm:px-6 lg:px-8">
        <Link to="/" className="flex items-center gap-2 text-ivory">
          <TreePine className="h-7 w-7 text-amber" />
          <span className="font-display text-xl font-bold tracking-tight">Savanna Park</span>
        </Link>

        <div className="hidden items-center gap-6 md:flex">
          {links.map((l) => (
            <NavLink key={l.to} to={l.to} className={navLinkClass} end={l.to === '/'}>
              {l.label}
            </NavLink>
          ))}

          {isVisitor ? (
            <div className="flex items-center gap-3">
              <span className="flex items-center gap-1.5 text-sm text-ivory/80">
                <User className="h-4 w-4" /> {name}
              </span>
              <button onClick={handleSignOut} className="btn-amber !px-4 !py-2 text-sm" aria-label="Sign out">
                <LogOut className="h-4 w-4" /> Sign out
              </button>
            </div>
          ) : !isStaff ? (
            <Link to="/account" className="btn-amber !px-4 !py-2 text-sm">Sign in</Link>
          ) : null}

          <Link to="/admin" className="text-sm font-medium text-ivory/60 hover:text-ivory">Staff</Link>
        </div>

        <button onClick={() => setOpen(!open)} className="text-ivory md:hidden" aria-label="Toggle menu">
          {open ? <X className="h-6 w-6" /> : <Menu className="h-6 w-6" />}
        </button>
      </div>

      <AnimatePresence>
        {open && (
          <motion.div
            initial={{ height: 0, opacity: 0 }} animate={{ height: 'auto', opacity: 1 }} exit={{ height: 0, opacity: 0 }}
            className="overflow-hidden border-t border-white/10 bg-forest md:hidden"
          >
            <div className="flex flex-col gap-1 px-4 py-4">
              {links.map((l) => (
                <NavLink key={l.to} to={l.to} onClick={() => setOpen(false)} className={navLinkClass} end={l.to === '/'}>
                  {l.label}
                </NavLink>
              ))}
              {isVisitor ? (
                <button onClick={handleSignOut} className="btn-amber mt-3 text-center text-sm">
                  <LogOut className="h-4 w-4" /> Sign out ({name})
                </button>
              ) : !isStaff ? (
                <Link to="/account" onClick={() => setOpen(false)} className="btn-amber mt-3 text-center text-sm">Sign in</Link>
              ) : null}
              <Link to="/admin" onClick={() => setOpen(false)} className="mt-2 text-center text-sm text-ivory/60">
                Staff Portal
              </Link>
            </div>
          </motion.div>
        )}
      </AnimatePresence>
    </nav>
  );
}
