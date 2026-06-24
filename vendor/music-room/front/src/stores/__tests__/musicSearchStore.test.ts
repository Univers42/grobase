import { useMusicSearchStore } from '../musicSearchStore';

describe('musicSearchStore', () => {
  beforeEach(() => {
    useMusicSearchStore.setState({
      query: '',
      results: [],
      loading: false,
      error: null,
      recentSearches: [],
    });
  });

  it('has correct initial state', () => {
    const state = useMusicSearchStore.getState();
    expect(state.query).toBe('');
    expect(state.results).toEqual([]);
    expect(state.loading).toBe(false);
    expect(state.error).toBeNull();
  });

  it('sets search query', () => {
    useMusicSearchStore.getState().setQuery('bohemian');
    expect(useMusicSearchStore.getState().query).toBe('bohemian');
  });

  it('sets search results', () => {
    const results = [{ id: '1', title: 'Bohemian Rhapsody', artist: 'Queen' }];
    useMusicSearchStore.getState().setResults(results as any);
    expect(useMusicSearchStore.getState().results).toEqual(results);
  });

  it('sets loading state', () => {
    useMusicSearchStore.getState().setLoading(true);
    expect(useMusicSearchStore.getState().loading).toBe(true);
  });

  it('clears results', () => {
    useMusicSearchStore.getState().setResults([{ id: '1' }] as any);
    useMusicSearchStore.getState().clearResults();
    expect(useMusicSearchStore.getState().results).toEqual([]);
    expect(useMusicSearchStore.getState().query).toBe('');
  });

  it('adds to recent searches', () => {
    useMusicSearchStore.getState().addRecentSearch('queen');
    useMusicSearchStore.getState().addRecentSearch('beatles');
    expect(useMusicSearchStore.getState().recentSearches).toEqual(['beatles', 'queen']);
  });
});
