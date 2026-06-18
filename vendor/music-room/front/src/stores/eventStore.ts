import { create } from 'zustand';
import { eventApi } from '../services/endpoints';

interface Event {
  _id: string;
  name: string;
  description?: string;
  creator: any;
  licenseType: 'OPEN' | 'INVITED_ONLY' | 'GEO_TIME';
  location?: { type: string; coordinates: [number, number] };
  timeWindow?: { start: string; end: string };
  participants: string[];
  playlist: any[];
  tags: string[];
  createdAt: string;
}

interface EventState {
  events: Event[];
  currentEvent: Event | null;
  loading: boolean;
  error: string | null;

  fetchEvents: () => Promise<void>;
  fetchNearby: (lat: number, lng: number, radius?: number) => Promise<void>;
  fetchEventById: (id: string) => Promise<void>;
  createEvent: (data: any) => Promise<Event>;
  joinEvent: (id: string) => Promise<void>;
  leaveEvent: (id: string) => Promise<void>;
  suggestTrack: (eventId: string, track: any) => Promise<void>;
  voteForTrack: (eventId: string, trackId: string) => Promise<void>;
  removeVote: (eventId: string, trackId: string) => Promise<void>;
  clearCurrent: () => void;
  clearError: () => void;
}

export const useEventStore = create<EventState>((set, get) => ({
  events: [],
  currentEvent: null,
  loading: false,
  error: null,

  fetchEvents: async () => {
    set({ loading: true, error: null });
    try {
      const events = await eventApi.getEvents();
      set({ events, loading: false });
    } catch (err: any) {
      set({ error: err.message, loading: false });
    }
  },

  fetchNearby: async (lat: number, lng: number, radius = 5000) => {
    set({ loading: true, error: null });
    try {
      const events = await eventApi.getNearbyEvents(lat, lng, radius);
      set({ events, loading: false });
    } catch (err: any) {
      set({ error: err.message, loading: false });
    }
  },

  fetchEventById: async (id: string) => {
    set({ loading: true, error: null });
    try {
      const event = await eventApi.getEvent(id);
      set({ currentEvent: event, loading: false });
    } catch (err: any) {
      set({ error: err.message, loading: false });
    }
  },

  createEvent: async (data: any) => {
    set({ loading: true, error: null });
    try {
      const event = await eventApi.createEvent(data);
      set((state) => ({
        events: [event, ...state.events],
        loading: false,
      }));
      return event;
    } catch (err: any) {
      set({ error: err.message, loading: false });
      throw err;
    }
  },

  joinEvent: async (id: string) => {
    try {
      await eventApi.joinEvent(id);
      const { currentEvent } = get();
      if (currentEvent && currentEvent._id === id) {
        await get().fetchEventById(id);
      }
    } catch (err: any) {
      set({ error: err.message });
    }
  },

  leaveEvent: async (id: string) => {
    try {
      await eventApi.leaveEvent(id);
      const { currentEvent } = get();
      if (currentEvent && currentEvent._id === id) {
        await get().fetchEventById(id);
      }
    } catch (err: any) {
      set({ error: err.message });
    }
  },

  suggestTrack: async (eventId: string, track: any) => {
    try {
      await eventApi.suggestTrack(eventId, track);
      await get().fetchEventById(eventId);
    } catch (err: any) {
      set({ error: err.message });
    }
  },

  voteForTrack: async (eventId: string, trackId: string) => {
    try {
      await eventApi.voteForTrack(eventId, trackId);
      await get().fetchEventById(eventId);
    } catch (err: any) {
      set({ error: err.message });
    }
  },

  removeVote: async (eventId: string, trackId: string) => {
    try {
      await eventApi.removeVote(eventId, trackId);
      await get().fetchEventById(eventId);
    } catch (err: any) {
      set({ error: err.message });
    }
  },

  clearCurrent: () => set({ currentEvent: null }),
  clearError: () => set({ error: null }),
}));
