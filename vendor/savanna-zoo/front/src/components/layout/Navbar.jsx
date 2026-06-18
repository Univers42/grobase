import { useState } from 'react';
import { Link, NavLink } from 'react-router-dom';
import { motion, AnimatePresence } from 'framer-motion';
import { Menu, X, TreePine } from 'lucide-react';

const links = [
  { to: '/',        label: 'Home' },
  { to: '/animals', label: 'Animals' },
  { to: '/events',  label: 'Events' },
  { to: '/tickets', label: 'Tickets' },
  { to: '/contact', label: 'Contact' },
];

const navLinkClass = ({ isActive }) =>
  `relative px-1 py-2 text-sm font-medium transition-colors duration-200 ${
    isActive
      ? 'text-amber'
      : 'text-ivory/80 hover:text-ivory'
  }`;

export default function Navbar() {
  const [open, setOpen] = useState(false);

  return (
    <nav className="fixed inset-x-0 top-0 z-50 glass bg-forest/90 backdrop-blur-lg border-b border-white/10">
      <div className="mx-auto flex h-16 max-w-7xl items-center justify-between px-4 sm:px-6 lg:px-8">
        {/* Logo */}
        <Link to="/" className="flex items-center gap-2 text-ivory">
          <TreePine className="h-7 w-7 text-amber" />
          <span className="font-display text-xl font-bold tracking-tight">
            Savanna Park
          </span>
        </Link>

        {/* Desktop links */}
        <div className="hidden items-center gap-6 md:flex">
          {links.map((l) => (
            <NavLink key={l.to} to={l.to} className={navLinkClass} end={l.to === '/'}>
              {l.label}
            </NavLink>
          ))}
          <Link to="/admin" className="btn-amber !px-4 !py-2 text-sm">
            Staff Portal
          </Link>
        </div>

        {/* Mobile hamburger */}
        <button
          onClick={() => setOpen(!open)}
          className="text-ivory md:hidden"
          aria-label="Toggle menu"
        >
          {open ? <X className="h-6 w-6" /> : <Menu className="h-6 w-6" />}
        </button>
      </div>

      {/* Mobile drawer */}
      <AnimatePresence>
        {open && (
          <motion.div
            initial={{ height: 0, opacity: 0 }}
            animate={{ height: 'auto', opacity: 1 }}
            exit={{ height: 0, opacity: 0 }}
            className="overflow-hidden border-t border-white/10 bg-forest md:hidden"
          >
            <div className="flex flex-col gap-1 px-4 py-4">
              {links.map((l) => (
                <NavLink
                  key={l.to}
                  to={l.to}
                  onClick={() => setOpen(false)}
                  className={navLinkClass}
                  end={l.to === '/'}
                >
                  {l.label}
                </NavLink>
              ))}
              <Link
                to="/admin"
                onClick={() => setOpen(false)}
                className="btn-amber mt-3 text-center text-sm"
              >
                Staff Portal
              </Link>
            </div>
          </motion.div>
        )}
      </AnimatePresence>
    </nav>
  );
}
