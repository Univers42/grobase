import { useState } from 'react';
import { NavLink, Link, useNavigate } from 'react-router-dom';
import useBaasAuth from '@/hooks/useBaasAuth';

const LINKS = [
  { to: '/', label: 'Inicio', end: true },
  { to: '/playas', label: 'Playas' },
  { to: '/mapa', label: 'Mapa' },
  { to: '/blog', label: 'Blog' },
  { to: '/reportes', label: 'Reportes' },
  { to: '/ranking', label: 'Ranking' },
  { to: '/comunidad', label: 'Comunidad' },
];

function navClass({ isActive }) {
  return `rounded-full px-4 py-2 transition hover:bg-white hover:text-ocean ${
    isActive ? 'bg-white text-ocean shadow-sm' : ''
  }`;
}

/** Account-aware top navigation. Shows Acceder when signed out; name + favoritos + logout when signed in. */
export default function Navbar() {
  const { user, name, signOut } = useBaasAuth();
  const [open, setOpen] = useState(false);
  const navigate = useNavigate();

  async function handleLogout() {
    await signOut();
    setOpen(false);
    navigate('/');
  }

  return (
    <header className="relative z-30">
      <div className="mx-auto grid max-w-7xl grid-cols-[auto_1fr_auto] items-center gap-4 px-5 py-6 sm:px-8 lg:px-10">
        <Link to="/" className="inline-flex items-center gap-3" aria-label="Surfind Spain">
          <span className="grid size-12 place-items-center rounded-full bg-white text-2xl shadow-sm shadow-ocean-teal/20">
            🌊
          </span>
          <span className="hidden text-lg font-black tracking-tight text-ocean sm:inline">Surfind Spain</span>
        </Link>

        <nav className="hidden items-center justify-center gap-1 justify-self-center rounded-full border border-ocean-sky/40 bg-white/55 p-1 text-sm font-semibold text-ocean-mid shadow-sm backdrop-blur lg:flex">
          {LINKS.map((l) => (
            <NavLink key={l.to} to={l.to} end={l.end} className={navClass}>
              {l.label}
            </NavLink>
          ))}
        </nav>

        <div className="justify-self-end text-sm font-semibold">
          {user ? (
            <div className="flex items-center gap-2">
              <NavLink to="/bitacora" className={({ isActive }) => `hidden md:inline-flex ${navClass({ isActive })}`}>
                📒 Bitácora
              </NavLink>
              <NavLink to="/perfil" className={({ isActive }) => `hidden md:inline-flex ${navClass({ isActive })}`} title={name || undefined}>
                Perfil
              </NavLink>
              <NavLink to="/mis-favoritos" className={navClass}>
                <span aria-hidden="true">♥</span> Mis favoritos
              </NavLink>
              <button onClick={handleLogout} className="btn-ghost">
                Cerrar sesión
              </button>
            </div>
          ) : (
            <div className="flex items-center gap-2">
              <Link to="/acceder" className="btn-ghost">
                Acceder
              </Link>
              <Link to="/registro" className="btn-primary px-5 py-2.5">
                Crear cuenta
              </Link>
            </div>
          )}
        </div>
      </div>

      <nav className="mx-auto mb-4 flex max-w-[calc(100%-2.5rem)] justify-center gap-2 overflow-x-auto rounded-full border border-ocean-sky/40 bg-white/60 p-1 text-sm font-semibold text-ocean-mid shadow-sm backdrop-blur lg:hidden">
        {LINKS.map((l) => (
          <NavLink key={l.to} to={l.to} end={l.end} className={({ isActive }) => `shrink-0 ${navClass({ isActive })}`}>
            {l.label}
          </NavLink>
        ))}
      </nav>
    </header>
  );
}
