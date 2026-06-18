import { create } from 'zustand';
import { playlistApi } from '../services/endpoints';

interface PlaylistTrack {
  deezerTrackId: string;
  title: string;
  artist: string;
  albumCover?: string;
  previewUrl?: string;
  addedBy: string;
  addedAt: string;
}

interface Playlist {
  _id: string;
  name: string;
  description?: string;
  owner: any;
  collaborators: string[];
  tracks: PlaylistTrack[];
  visibility: 'PUBLIC' | 'FRIENDS_ONLY' | 'PRIVATE';
  collaborationType: 'OPEN' | 'INVITE_ONLY' | 'VOTE_TO_ADD';
  tags: string[];
  version: number;
  createdAt: string;
}

interface PlaylistState {
  playlists: Playlist[];
  currentPlaylist: Playlist | null;
  loading: boolean;
  error: string | null;

  fetchPlaylists: () => Promise<void>;
  fetchPlaylistById: (id: string) => Promise<void>;
  createPlaylist: (data: any) => Promise<Playlist>;
  updatePlaylist: (id: string, data: any) => Promise<void>;
  deletePlaylist: (id: string) => Promise<void>;
  addTrack: (playlistId: string, track: any, baseVersion: number) => Promise<void>;
  removeTrack: (playlistId: string, trackId: string, baseVersion: number) => Promise<void>;
  reorderTracks: (playlistId: string, trackId: string, newIndex: number, baseVersion: number) => Promise<void>;
  clearCurrent: () => void;
  clearError: () => void;
}

export const usePlaylistStore = create<PlaylistState>((set, get) => ({
  playlists: [],
  currentPlaylist: null,
  loading: false,
  error: null,

  fetchPlaylists: async () => {
    set({ loading: true, error: null });
    try {
      const playlists = await playlistApi.getPlaylists();
      set({ playlists, loading: false });
    } catch (err: any) {
      set({ error: err.message, loading: false });
    }
  },

  fetchPlaylistById: async (id: string) => {
    set({ loading: true, error: null });
    try {
      const playlist = await playlistApi.getPlaylist(id);
      set({ currentPlaylist: playlist, loading: false });
    } catch (err: any) {
      set({ error: err.message, loading: false });
    }
  },

  createPlaylist: async (data: any) => {
    set({ loading: true, error: null });
    try {
      const playlist = await playlistApi.createPlaylist(data);
      set((state) => ({
        playlists: [playlist, ...state.playlists],
        loading: false,
      }));
      return playlist;
    } catch (err: any) {
      set({ error: err.message, loading: false });
      throw err;
    }
  },

  updatePlaylist: async (id: string, data: any) => {
    try {
      const updated = await playlistApi.updatePlaylist(id, data);
      set((state) => ({
        playlists: state.playlists.map((p) => (p._id === id ? updated : p)),
        currentPlaylist: state.currentPlaylist?._id === id ? updated : state.currentPlaylist,
      }));
    } catch (err: any) {
      set({ error: err.message });
    }
  },

  deletePlaylist: async (id: string) => {
    try {
      await playlistApi.deletePlaylist(id);
      set((state) => ({
        playlists: state.playlists.filter((p) => p._id !== id),
        currentPlaylist: state.currentPlaylist?._id === id ? null : state.currentPlaylist,
      }));
    } catch (err: any) {
      set({ error: err.message });
    }
  },

  addTrack: async (playlistId: string, track: any, baseVersion: number) => {
    try {
      await playlistApi.addTrack(playlistId, { ...track, baseVersion });
      await get().fetchPlaylistById(playlistId);
    } catch (err: any) {
      set({ error: err.message });
    }
  },

  removeTrack: async (playlistId: string, trackId: string, baseVersion: number) => {
    try {
      await playlistApi.removeTrack(playlistId, { deezerTrackId: trackId, baseVersion });
      await get().fetchPlaylistById(playlistId);
    } catch (err: any) {
      set({ error: err.message });
    }
  },

  reorderTracks: async (playlistId: string, trackId: string, newIndex: number, baseVersion: number) => {
    try {
      await playlistApi.reorderTracks(playlistId, { deezerTrackId: trackId, newIndex, baseVersion });
      await get().fetchPlaylistById(playlistId);
    } catch (err: any) {
      set({ error: err.message });
    }
  },

  clearCurrent: () => set({ currentPlaylist: null }),
  clearError: () => set({ error: null }),
}));
