import { useEffect, useState } from 'react';
import baas from '@/baas/client';

/**
 * Owner-scoped favorite toggle for one beach. A plain GET /rest/v1/favorites
 * returns only the caller's rows (RLS owner-scope), so presence = "is mine".
 * Mutations send the user Bearer (client attaches the localStorage token).
 */
export default function useFavorite(beachId, enabled) {
  const [saved, setSaved] = useState(false);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    if (!enabled || !beachId) { setSaved(false); return; }
    baas
      .collection('favorites')
      .select('beach_id')
      .eq('beach_id', beachId)
      .get()
      .then((rows) => setSaved(rows.length > 0))
      .catch(() => setSaved(false));
  }, [beachId, enabled]);

  async function toggle() {
    if (busy || !beachId) return;
    setBusy(true);
    try {
      if (saved) {
        await baas.collection('favorites').eq('beach_id', beachId).remove();
        setSaved(false);
      } else {
        await baas.collection('favorites').insert({ beach_id: beachId });
        setSaved(true);
      }
    } finally {
      setBusy(false);
    }
  }

  return { saved, busy, toggle };
}
