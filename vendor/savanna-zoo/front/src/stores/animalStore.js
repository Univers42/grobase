import { create } from 'zustand';
import baas from '@/baas/client';

export const useAnimalStore = create((set, get) => ({
  animals: [],
  featured: [],
  current: null,
  loading: false,
  error: null,

  /** Fetch all animals (public — only active returned by BaaS rules) */
  fetchAnimals: async (filters = {}) => {
    set({ loading: true, error: null });
    try {
      let q = baas.collection('animals').order('name', 'asc');
      Object.entries(filters).forEach(([k, v]) => { q = q.eq(k, v); });
      const animals = await q.get();
      set({ animals, loading: false });
    } catch (err) {
      set({ error: err.message, loading: false });
    }
  },

  /** Fetch featured animals for the homepage hero */
  fetchFeatured: async () => {
    try {
      const featured = await baas
        .collection('animals')
        .eq('is_featured', true)
        .limit(5)
        .get();
      set({ featured });
    } catch {
      /* silent — featured is decorative */
    }
  },

  /** Fetch a single animal with keeper + health records */
  fetchAnimal: async (id) => {
    set({ loading: true, error: null, current: null });
    try {
      const animal = await baas
        .collection('animals')
        .eq('id', id)
        .join('animal_with_keeper')
        .single();
      set({ current: animal, loading: false });
    } catch (err) {
      set({ error: err.message, loading: false });
    }
  },
}));
