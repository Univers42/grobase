import { create } from 'zustand';
import { musicApi } from '../services/endpoints';

interface SearchResult {
  id: number;
  title: string;
  artist: { id: number; name: string; picture_medium?: string };
  album: { id: number; title: string; cover_medium?: string };
  preview: string;
  duration: number;
}

interface MusicSearchState {
  results: SearchResult[];
  query: string;
  loading: boolean;
  error: string | null;
  recentSearches: string[];

  search: (query: string, limit?: number) => Promise<void>;
  getTrack: (trackId: number) => Promise<any>;
  getArtist: (artistId: number) => Promise<any>;
  getArtistTopTracks: (artistId: number) => Promise<any[]>;
  addRecentSearch: (query: string) => void;
  clearResults: () => void;
  clearError: () => void;
}

const MAX_RECENT_SEARCHES = 10;

export const useMusicSearchStore = create<MusicSearchState>((set, get) => ({
  results: [],
  query: '',
  loading: false,
  error: null,
  recentSearches: [],

  search: async (query: string, limit = 25) => {
    if (!query.trim()) {
      set({ results: [], query: '' });
      return;
    }
    set({ loading: true, error: null, query });
    try {
      const response = await musicApi.searchTracks(query, limit);
      set({ results: response.data || response, loading: false });
      get().addRecentSearch(query);
    } catch (err: any) {
      set({ error: err.message, loading: false });
    }
  },

  getTrack: async (trackId: number) => {
    try {
      return await musicApi.getTrack(trackId);
    } catch (err: any) {
      set({ error: err.message });
      return null;
    }
  },

  getArtist: async (artistId: number) => {
    try {
      return await musicApi.getArtist(artistId);
    } catch (err: any) {
      set({ error: err.message });
      return null;
    }
  },

  getArtistTopTracks: async (artistId: number) => {
    try {
      return await musicApi.getArtistTopTracks(artistId);
    } catch (err: any) {
      set({ error: err.message });
      return [];
    }
  },

  addRecentSearch: (query: string) => {
    set((state) => {
      const filtered = state.recentSearches.filter((s) => s !== query);
      return {
        recentSearches: [query, ...filtered].slice(0, MAX_RECENT_SEARCHES),
      };
    });
  },

  clearResults: () => set({ results: [], query: '' }),
  clearError: () => set({ error: null }),
}));
