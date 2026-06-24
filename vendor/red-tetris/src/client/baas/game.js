// Persist a finished game. The row is owner-scoped (the data plane stamps
// owner_id from the JWT); player_id is the GoTrue sub so the apply_game_result
// trigger upserts the right player_stats + ELO rating, and the CDC write makes
// the leaderboard update live.
import { insertRow } from './query.js';
import { currentUserId } from './session.js';

/**
 * postGame records one completed game and returns the inserted row.
 * Silently no-ops (resolves null) when there is no signed-in user.
 *
 * @param {{mode?:string,score?:number,lines?:number,level?:number,
 *          durationS?:number,won?:boolean,room?:string|null,startedAt?:string}} r
 */
export async function postGame(r = {}) {
  const playerId = currentUserId();
  if (!playerId) return null;
  return insertRow('games', {
    player_id: playerId,
    room: r.room ?? null,
    mode: r.mode ?? 'solo',
    score: r.score ?? 0,
    lines: r.lines ?? 0,
    level: r.level ?? 1,
    duration_s: r.durationS ?? 0,
    won: r.won ?? false,
    started_at: r.startedAt ?? null,
  });
}
