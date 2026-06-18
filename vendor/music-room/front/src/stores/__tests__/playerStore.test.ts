import { usePlayerStore } from '../../stores/playerStore';

beforeEach(() => {
  usePlayerStore.setState({
    currentTrack: null,
    isPlaying: false,
    position: 0,
    duration: 0,
    volume: 1,
    queue: [],
    queueIndex: -1,
  });
});

describe('playerStore', () => {
  const mockTrack = {
    id: 'track-1',
    title: 'Test Song',
    artist: 'Test Artist',
    preview: 'https://example.com/preview.mp3',
    albumCover: 'https://example.com/cover.jpg',
    duration: 30,
  };

  it('should have initial idle state', () => {
    const state = usePlayerStore.getState();
    expect(state.currentTrack).toBeNull();
    expect(state.isPlaying).toBe(false);
    expect(state.queue).toEqual([]);
  });

  it('should set current track', () => {
    usePlayerStore.getState().setTrack(mockTrack as any);
    expect(usePlayerStore.getState().currentTrack).toEqual(mockTrack);
  });

  it('should toggle playing state', () => {
    usePlayerStore.getState().setPlaying(true);
    expect(usePlayerStore.getState().isPlaying).toBe(true);

    usePlayerStore.getState().setPlaying(false);
    expect(usePlayerStore.getState().isPlaying).toBe(false);
  });

  it('should update position', () => {
    usePlayerStore.getState().setPosition(15000);
    expect(usePlayerStore.getState().position).toBe(15000);
  });

  it('should update volume', () => {
    usePlayerStore.getState().setVolume(0.5);
    expect(usePlayerStore.getState().volume).toBe(0.5);
  });

  it('should manage queue', () => {
    const tracks = [mockTrack, { ...mockTrack, id: 'track-2', title: 'Song 2' }];
    usePlayerStore.getState().setQueue(tracks as any[]);
    expect(usePlayerStore.getState().queue).toHaveLength(2);
  });

  it('should clear player state on stop', () => {
    usePlayerStore.getState().setTrack(mockTrack as any);
    usePlayerStore.getState().setPlaying(true);
    usePlayerStore.getState().stop();

    const state = usePlayerStore.getState();
    expect(state.isPlaying).toBe(false);
    expect(state.position).toBe(0);
  });
});
