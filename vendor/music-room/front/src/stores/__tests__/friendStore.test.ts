import { useFriendStore } from '../friendStore';

describe('friendStore', () => {
  beforeEach(() => {
    useFriendStore.setState({
      friends: [],
      pendingRequests: [],
      sentRequests: [],
      loading: false,
      error: null,
    });
  });

  it('has correct initial state', () => {
    const state = useFriendStore.getState();
    expect(state.friends).toEqual([]);
    expect(state.pendingRequests).toEqual([]);
    expect(state.sentRequests).toEqual([]);
    expect(state.loading).toBe(false);
  });

  it('sets friends list', () => {
    const friends = [
      { id: '1', username: 'alice' },
      { id: '2', username: 'bob' },
    ];
    useFriendStore.getState().setFriends(friends as any);
    expect(useFriendStore.getState().friends).toEqual(friends);
  });

  it('sets pending requests', () => {
    const requests = [{ id: '1', from: 'charlie' }];
    useFriendStore.getState().setPendingRequests(requests as any);
    expect(useFriendStore.getState().pendingRequests).toEqual(requests);
  });

  it('sets loading state', () => {
    useFriendStore.getState().setLoading(true);
    expect(useFriendStore.getState().loading).toBe(true);
  });

  it('sets error state', () => {
    useFriendStore.getState().setError('Network error');
    expect(useFriendStore.getState().error).toBe('Network error');
  });
});
