// sessionStats.js — derive the bitácora summary from a surfer's session docs.
// Pure: total sesiones, olas, horas (Σ duration), spots distintos, mejor
// valoración, racha (consecutive-day streak ending today/yesterday).

function dayKey(iso) {
  const d = new Date(iso);
  return Number.isNaN(d.getTime()) ? null : d.toISOString().slice(0, 10);
}

// Longest run of consecutive calendar days present in the session set, counted
// back from the most recent session day.
function streak(sessions) {
  const days = new Set(sessions.map((s) => dayKey(s.date || s.created_at)).filter(Boolean));
  if (!days.size) return 0;
  const sorted = [...days].sort().reverse();
  let run = 1;
  let prev = new Date(sorted[0]);
  for (let i = 1; i < sorted.length; i += 1) {
    const cur = new Date(sorted[i]);
    const gap = Math.round((prev - cur) / 86400000);
    if (gap === 1) { run += 1; prev = cur; } else break;
  }
  return run;
}

/** Compute the stats summary for an array of session documents. */
export default function sessionStats(sessions) {
  const list = sessions || [];
  const totalMin = list.reduce((a, s) => a + (Number(s.duration_min) || 0), 0);
  const waves = list.reduce((a, s) => a + (Number(s.waves) || 0), 0);
  const spots = new Set(list.map((s) => s.beach_name || s.beach_id).filter(Boolean)).size;
  const best = list.reduce((m, s) => Math.max(m, Number(s.rating) || 0), 0);
  return {
    sessions: list.length,
    waves,
    hours: Math.round((totalMin / 60) * 10) / 10,
    spots,
    best,
    streak: streak(list),
  };
}
