// Profile + competitive data reads. Profiles/stats/ratings are world-readable
// (shared app-key reads); games are owner-scoped (the Bearer scopes them to me).
import { listRows, sharedList } from './query.js';
import { currentUserId } from './session.js';

/** myProfile loads the signed-in player's profile, stats, rating, and recent games. */
export async function myProfile() {
  const id = currentUserId();
  const [profiles, stats, ratings, games] = await Promise.all([
    sharedList('profiles', { limit: 200 }),
    sharedList('player_stats', { limit: 500 }),
    sharedList('ratings', { limit: 500 }),
    listRows('games', { sort: { ended_at: 'desc' }, limit: 10 }),
  ]);
  return {
    profile: profiles.find((p) => p.id === id) || null,
    stats: stats.find((s) => s.player_id === id) || null,
    rating: ratings.find((r) => r.player_id === id) || null,
    games: games || [],
  };
}

/** leaderboard loads the global games_leaderboard ranked by max_score (shared). */
export function leaderboard(limit = 50) {
  return sharedList('games_leaderboard', { sort: { max_score: 'desc' }, limit });
}

/** standings loads the season classement snapshot ranked by global_rank (shared). */
export function standings(limit = 100) {
  return sharedList('standings', { sort: { global_rank: 'asc' }, limit });
}

/**
 * classement derives the LIVE league table from current ratings (the trigger
 * maintains ratings.league_tier per game, so promotion/relegation is automatic)
 * joined to profiles for display. Recomputed on every games CDC event — no
 * scheduler needed because the classement is a pure function of ratings.
 */
export async function classement(limit = 200) {
  const [ratings, profiles] = await Promise.all([
    sharedList('ratings', { sort: { rating: 'desc' }, limit }),
    sharedList('profiles', { limit }),
  ]);
  const byId = new Map(profiles.map((p) => [p.id, p]));
  const tierRank = {};
  return ratings.map((r, i) => {
    tierRank[r.league_tier] = (tierRank[r.league_tier] || 0) + 1;
    const p = byId.get(r.player_id) || {};
    return {
      player_id: r.player_id,
      username: p.username || 'player',
      country: p.country || '',
      rating: r.rating,
      league_tier: r.league_tier,
      rank: tierRank[r.league_tier],
      global_rank: i + 1,
      points: r.rating,
    };
  });
}

/** leagueTiers loads the static Bronze..Diamond tier reference (shared). */
export function leagueTiers() {
  return sharedList('league_tiers', { sort: { rank_order: 'asc' }, limit: 20 });
}
