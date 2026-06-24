import { Link } from 'react-router-dom';

export default function Footer() {
  return (
    <footer className="relative z-10 mt-16 border-t border-ocean-sky/30 bg-white/55 backdrop-blur">
      <div className="mx-auto grid max-w-7xl gap-6 px-5 py-8 text-sm text-ocean-mid sm:px-8 md:grid-cols-3 md:items-center lg:px-10">
        <p className="text-ocean-mid/80">Encuentra tu playa de surf en España.</p>
        <div className="justify-self-start text-left md:justify-self-center md:text-center">
          <Link to="/" className="text-2xl font-black uppercase tracking-[0.28em] text-ocean transition hover:text-ocean-mid">
            Surfind Spain
          </Link>
        </div>
        <p className="text-ocean-mid/80 md:justify-self-end md:text-right">
          Proyecto re-platformado sobre Grobase BaaS
        </p>
      </div>
    </footer>
  );
}
