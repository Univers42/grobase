/**
 * PublicDataContext — Centralised data fetching for public pages.
 *
 * All shared read-only data (site info, working hours, reviews, stats) is
 * fetched **once** when PublicSPA mounts and exposed via context so that
 * Footer, Home, Contact … receive it via `usePublicData()` instead of each
 * component firing its own API calls on every page navigation.
 */

import { createContext, useContext, useCallback, useEffect, useState, type ReactNode } from 'react';
import { useLiveRefresh } from '../services/useLiveRefresh';
import {
  fetchSiteInfo,
  fetchWorkingHours,
  fetchApprovedReviews,
  fetchReviewStats,
  type SiteInfo,
  type WorkingHour,
  type PublicReview,
  type ReviewStats,
} from '../services/public';

/* ------------------------------------------------------------------ */
/*  Types                                                              */
/* ------------------------------------------------------------------ */

export interface PublicData {
  siteInfo: SiteInfo | null;
  workingHours: WorkingHour[];
  reviews: PublicReview[];
  reviewStats: ReviewStats | null;
  loading: boolean;
}

const defaultValue: PublicData = {
  siteInfo: null,
  workingHours: [],
  reviews: [],
  reviewStats: null,
  loading: false,
};

/* ------------------------------------------------------------------ */
/*  Context & hook                                                     */
/* ------------------------------------------------------------------ */

const PublicDataCtx = createContext<PublicData>(defaultValue);

// eslint-disable-next-line react-refresh/only-export-components
export function usePublicData(): PublicData {
  return useContext(PublicDataCtx);
}

/* ------------------------------------------------------------------ */
/*  Provider                                                           */
/* ------------------------------------------------------------------ */

const DAY_ORDER = ['Lundi', 'Mardi', 'Mercredi', 'Jeudi', 'Vendredi', 'Samedi', 'Dimanche'];

function logPublicDataWarning(message: string, err: unknown) {
  if (import.meta.env.DEV) {
    console.warn(message, err);
  }
}

export function PublicDataProvider({ children }: Readonly<{ children: ReactNode }>) {
  const [data, setData] = useState<PublicData>(defaultValue);

  const loadHeroData = useCallback(async () => {
    try {
      const [info, stats] = await Promise.all([fetchSiteInfo(), fetchReviewStats()]);
      setData((prev) => ({ ...prev, siteInfo: info, reviewStats: stats }));
    } catch (err) {
      logPublicDataWarning('[PublicDataProvider] Failed to fetch hero public data:', err);
    }
  }, []);

  const loadDeferredData = useCallback(async () => {
    try {
      const [hours, rawReviews] = await Promise.all([fetchWorkingHours(), fetchApprovedReviews(1, 20)]);
      hours.sort((a, b) => DAY_ORDER.indexOf(a.day) - DAY_ORDER.indexOf(b.day));
      setData((prev) => ({ ...prev, workingHours: hours, reviews: rawReviews, loading: false }));
    } catch (err) {
      logPublicDataWarning('[PublicDataProvider] Failed to fetch deferred public data:', err);
      setData((prev) => ({ ...prev, loading: false }));
    }
  }, []);

  useEffect(() => {
    const heroTimer = globalThis.setTimeout(loadHeroData, 5000);
    const deferredTimer = globalThis.setTimeout(loadDeferredData, 8000);
    return () => {
      globalThis.clearTimeout(heroTimer);
      globalThis.clearTimeout(deferredTimer);
    };
  }, [loadHeroData, loadDeferredData]); // fetch once on mount

  // Live updates: reviews/site-info/hours/events refresh in place via realtime.
  const reloadLive = useCallback(() => {
    void loadHeroData();
    void loadDeferredData();
  }, [loadHeroData, loadDeferredData]);
  useLiveRefresh(['Publish', 'Company', 'CompanyOwner', 'Event', 'WorkingHours'], reloadLive);

  return <PublicDataCtx.Provider value={data}>{children}</PublicDataCtx.Provider>;
}
