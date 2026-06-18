import { usePlaylistStore } from '../playlistStore';

describe('playlistStore', () => {
  beforeEach(() => {
    usePlaylistStore.setState({
      playlists: [],
      currentPlaylist: null,
      tracks: [],
      loading: false,
      error: null,
    });
  });

  it('has correct initial state', () => {
    const state = usePlaylistStore.getState();
    expect(state.playlists).toEqual([]);
    expect(state.currentPlaylist).toBeNull();
    expect(state.tracks).toEqual([]);
    expect(state.loading).toBe(false);
  });

  it('sets playlists', () => {
    const mockPlaylists = [
      { id: '1', name: 'Playlist 1' },
      { id: '2', name: 'Playlist 2' },
    ];
    usePlaylistStore.getState().setPlaylists(mockPlaylists as any);
    expect(usePlaylistStore.getState().playlists).toEqual(mockPlaylists);
  });

  it('sets current playlist', () => {
    const mockPlaylist = { id: '1', name: 'My Playlist' };
    usePlaylistStore.getState().setCurrentPlaylist(mockPlaylist as any);
    expect(usePlaylistStore.getState().currentPlaylist).toEqual(mockPlaylist);
  });

  it('sets tracks', () => {
    const mockTracks = [{ id: '1', title: 'Track 1' }];
    usePlaylistStore.getState().setTracks(mockTracks as any);
    expect(usePlaylistStore.getState().tracks).toEqual(mockTracks);
  });

  it('sets loading state', () => {
    usePlaylistStore.getState().setLoading(true);
    expect(usePlaylistStore.getState().loading).toBe(true);
  });

  it('sets error state', () => {
    usePlaylistStore.getState().setError('Failed to load');
    expect(usePlaylistStore.getState().error).toBe('Failed to load');
  });
});
