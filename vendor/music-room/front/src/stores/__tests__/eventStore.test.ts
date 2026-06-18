import { useEventStore } from '../eventStore';

describe('eventStore', () => {
  beforeEach(() => {
    useEventStore.setState({
      events: [],
      currentEvent: null,
      nearbyEvents: [],
      loading: false,
      error: null,
    });
  });

  it('has correct initial state', () => {
    const state = useEventStore.getState();
    expect(state.events).toEqual([]);
    expect(state.currentEvent).toBeNull();
    expect(state.loading).toBe(false);
    expect(state.error).toBeNull();
  });

  it('sets events', () => {
    const mockEvents = [
      { id: '1', name: 'Event 1' },
      { id: '2', name: 'Event 2' },
    ];
    useEventStore.getState().setEvents(mockEvents as any);
    expect(useEventStore.getState().events).toEqual(mockEvents);
  });

  it('sets current event', () => {
    const mockEvent = { id: '1', name: 'Test Event' };
    useEventStore.getState().setCurrentEvent(mockEvent as any);
    expect(useEventStore.getState().currentEvent).toEqual(mockEvent);
  });

  it('sets loading state', () => {
    useEventStore.getState().setLoading(true);
    expect(useEventStore.getState().loading).toBe(true);
  });

  it('sets error state', () => {
    useEventStore.getState().setError('Something went wrong');
    expect(useEventStore.getState().error).toBe('Something went wrong');
  });

  it('sets nearby events', () => {
    const nearby = [{ id: '3', name: 'Nearby Event' }];
    useEventStore.getState().setNearbyEvents(nearby as any);
    expect(useEventStore.getState().nearbyEvents).toEqual(nearby);
  });

  it('clears current event', () => {
    useEventStore.getState().setCurrentEvent({ id: '1' } as any);
    useEventStore.getState().setCurrentEvent(null);
    expect(useEventStore.getState().currentEvent).toBeNull();
  });
});
