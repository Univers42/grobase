import { useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import baas from '@/baas/client';
import { subscribe } from '@/baas/realtime';
import useBaasAuth from '@/hooks/useBaasAuth';
import ReportCard from '@/components/ReportCard';
import ReportForm from '@/components/ReportForm';
import LoadingScreen from '@/components/ui/LoadingScreen';

/** Reportes en vivo — global live feed across all beaches. New reports prepend
 *  live via realtime pg/surf_reports/inserted. Signed-in users get a quick form. */
export default function Reportes() {
  const { user, name } = useBaasAuth();
  const [reports, setReports] = useState(null);
  const [beaches, setBeaches] = useState([]);

  useEffect(() => {
    baas
      .collection('surf_reports')
      .select('*,beach:beaches(name,slug)')
      .order('created_at', 'desc')
      .limit(40)
      .get()
      .then(setReports)
      .catch(() => setReports([]));

    baas.collection('beaches').select('id,name').eq('status', 'published').order('name').get()
      .then(setBeaches).catch(() => {});

    const unsub = subscribe('surf_reports', 'insert', (row) => {
      setReports((prev) => {
        const list = prev || [];
        if (list.some((r) => r.id === row.id)) return list;
        return [row, ...list].slice(0, 60);
      });
    });
    return unsub;
  }, []);

  function onPosted(row) {
    setReports((prev) => {
      const list = prev || [];
      return list.some((r) => r.id === row?.id) ? list : [row, ...list];
    });
  }

  return (
    <section className="mx-auto flex max-w-4xl flex-col gap-6 px-5 pb-16 pt-2 sm:px-8">
      <div className="flex items-end justify-between gap-3">
        <div>
          <p className="text-sm font-bold uppercase tracking-[0.28em] text-ocean-teal">Comunidad</p>
          <h1 className="mt-2 text-4xl font-black tracking-tight text-ocean md:text-5xl">Reportes en vivo</h1>
        </div>
        <span className="rounded-full bg-emerald-100 px-3 py-1 text-xs font-bold text-emerald-700">● en directo</span>
      </div>

      {user ? (
        <ReportForm beaches={beaches} authorName={name} onPosted={onPosted} />
      ) : (
        <div className="panel p-4 text-sm font-semibold text-ocean-mid">
          <Link to="/acceder" className="font-black text-ocean hover:text-ocean-mid">Inicia sesión</Link> para publicar un reporte de tu playa.
        </div>
      )}

      {reports === null ? (
        <LoadingScreen />
      ) : reports.length ? (
        <div className="space-y-3">
          {reports.map((r) => <ReportCard key={r.id} report={r} />)}
        </div>
      ) : (
        <p className="panel px-6 py-14 text-center font-semibold text-ocean-mid">Todavía no hay reportes. ¡Publica el primero!</p>
      )}
    </section>
  );
}
