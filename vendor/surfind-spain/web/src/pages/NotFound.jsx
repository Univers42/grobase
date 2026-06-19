import { Link } from 'react-router-dom';

export default function NotFound() {
  return (
    <section className="mx-auto grid min-h-[60vh] max-w-2xl place-items-center px-5 text-center">
      <div>
        <p className="text-6xl">🌊</p>
        <h1 className="mt-4 text-4xl font-black tracking-tight text-ocean">Página no encontrada</h1>
        <p className="mt-3 text-ocean-mid">La ola que buscabas se ha ido. Vuelve a la orilla.</p>
        <Link to="/" className="btn-primary mt-8">Volver al inicio</Link>
      </div>
    </section>
  );
}
