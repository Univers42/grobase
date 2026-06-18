import { useAuthStore } from '../../stores/authStore';

// Reset store between tests
beforeEach(() => {
  useAuthStore.setState({
    token: null,
    refreshToken: null,
    user: null,
    isAuthenticated: false,
    isLoading: false,
  });
});

describe('authStore', () => {
  it('should have initial unauthenticated state', () => {
    const state = useAuthStore.getState();
    expect(state.isAuthenticated).toBe(false);
    expect(state.token).toBeNull();
    expect(state.user).toBeNull();
  });

  it('should set tokens and user on login', () => {
    const mockUser = {
      _id: '123',
      username: 'testuser',
      email: 'test@example.com',
    };

    useAuthStore.getState().setAuth('access-token', 'refresh-token', mockUser as any);

    const state = useAuthStore.getState();
    expect(state.isAuthenticated).toBe(true);
    expect(state.token).toBe('access-token');
    expect(state.refreshToken).toBe('refresh-token');
    expect(state.user?.username).toBe('testuser');
  });

  it('should clear state on logout', () => {
    useAuthStore.getState().setAuth('token', 'refresh', { _id: '1' } as any);
    useAuthStore.getState().logout();

    const state = useAuthStore.getState();
    expect(state.isAuthenticated).toBe(false);
    expect(state.token).toBeNull();
    expect(state.user).toBeNull();
  });

  it('should update user profile', () => {
    useAuthStore.getState().setAuth('token', 'refresh', {
      _id: '1',
      username: 'original',
    } as any);

    useAuthStore.getState().updateUser({ username: 'updated' } as any);

    expect(useAuthStore.getState().user?.username).toBe('updated');
  });

  it('should toggle loading state', () => {
    expect(useAuthStore.getState().isLoading).toBe(false);
    useAuthStore.getState().setLoading(true);
    expect(useAuthStore.getState().isLoading).toBe(true);
  });
});
