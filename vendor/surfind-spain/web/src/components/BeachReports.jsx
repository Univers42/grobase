// BeachReports.jsx — 'Reportes recientes' for one beach. Lists recent surf_reports,
// prepends new ones live (realtime pg/surf_reports/inserted, filtered to this beach),
// and offers a post form to signed-in users.
import { useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import baas from '@/baas/client';
import { subscribe } from '@/baas/realtime';
import useBaasAuth from '@/hooks/useBaasAuth';
import ReportCard from '@/components/ReportCard';
import ReportForm from '@/components/ReportForm';

/** Recent + live surf reports for a single beach, with an auth post form. */
export default function BeachReports({ beachId }) {
  const { user, name } = useBaasAuth();
  const [reports, setReports] = useState(null);

  useEffect(() => {
    if (!beachId) return undefined;
    baas
      .collection('surf_reports')
      .select('*')
      .eq('beach_id', beachId)
      .order('created_at', 'desc')
      .limit(20)
      .get()
      .then(setReports)
      .catch(() => setReports([]));

    const unsub = subscribe('surf_reports', 'insert', (row) => {
      if (Number(row.beach_id) !== Number(beachId)) return;
      setReports((prev) => {
        const list = prev || [];
        if (list.some((r) => r.id === row.id)) return list;
        return [row, ...list];
      });
    });
    return unsub;
  }, [beachId]);

  function onPosted(row) {
    setReports((prev) => {
      const list = prev || [];
      return list.some((r) => r.id === row?.id) ? list : [row, ...list];
    });
  }

  return (
    <section className="panel p-6 md:p-8">
      <div className="flex items-end justify-between gap-3">
        <div>
          <p className="text-sm font-bold uppercase tracking-[0.28em] text-ocean-teal">En vivo</p>
          <h2 className="mt-2 text-2xl font-black text-ocean">Reportes recientes</h2>
        </div>
        <span className="rounded-full bg-emerald-100 px-3 py-1 text-xs font-bold text-emerald-700">● en directo</span>
      </div>

      {user ? (
        <div className="mt-6">
          <ReportForm beachId={beachId} authorName={name} onPosted={onPosted} />
        </div>
      ) : (
        <div className="mt-6 rounded-[1.5rem] bg-ocean-pale/45 p-4 text-sm font-semibold text-ocean-mid">
          <Link to="/acceder" className="font-black text-ocean hover:text-ocean-mid">Inicia sesión</Link> para publicar un reporte.
        </div>
      )}

      <div className="mt-6 space-y-3">
        {reports === null ? (
          <p className="text-sm font-semibold text-ocean-mid">Cargando reportes…</p>
        ) : reports.length ? (
          reports.map((r) => <ReportCard key={r.id} report={r} />)
        ) : (
          <p className="rounded-[1.5rem] bg-white/70 p-5 text-sm font-semibold text-ocean-mid shadow-sm">
            Aún no hay reportes de esta playa. ¡Sé el primero en avisar de cómo está!
          </p>
        )}
      </div>
    </section>
  );
}
