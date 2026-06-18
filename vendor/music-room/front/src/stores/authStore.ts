import { create } from 'zustand';
import * as SecureStore from 'expo-secure-store';
import { Platform } from 'react-native';
import { authApi, userApi } from '../services';

const TOKEN_KEY = 'auth_access_token';
const REFRESH_KEY = 'auth_refresh_token';

// SecureStore is not available on web — fallback to memory
const storage = {
  async get(key: string): Promise<string | null> {
    if (Platform.OS === 'web') return null;
    return SecureStore.getItemAsync(key);
  },
  async set(key: string, value: string): Promise<void> {
    if (Platform.OS === 'web') return;
    await SecureStore.setItemAsync(key, value);
  },
  async remove(key: string): Promise<void> {
    if (Platform.OS === 'web') return;
    await SecureStore.deleteItemAsync(key);
  },
};

type User = {
  _id: string;
  email: string;
  publicInfo?: {
    displayName?: string;
    avatar?: string;
    bio?: string;
  };
  [key: string]: any;
};

type AuthState = {
  user: User | null;
  token: string | null;
  refreshToken: string | null;
  isLoading: boolean;
  isAuthenticated: boolean;

  // Actions
  initialize: () => Promise<void>;
  login: (email: string, password: string) => Promise<void>;
  register: (email: string, password: string, displayName: string) => Promise<void>;
  loginWithGoogle: (idToken: string) => Promise<void>;
  loginWithFacebook: (accessToken: string) => Promise<void>;
  logout: () => Promise<void>;
  refreshTokens: () => Promise<boolean>;
  updateUser: (data: Partial<User>) => void;
};

export const useAuthStore = create<AuthState>((set, get) => ({
  user: null,
  token: null,
  refreshToken: null,
  isLoading: true,
  isAuthenticated: false,

  initialize: async () => {
    try {
      const token = await storage.get(TOKEN_KEY);
      const refreshToken = await storage.get(REFRESH_KEY);

      if (token) {
        try {
          const user = await userApi.getMe(token);
          set({ user, token, refreshToken, isAuthenticated: true, isLoading: false });
        } catch {
          // Token expired — try refresh
          if (refreshToken) {
            const success = await get().refreshTokens();
            if (!success) {
              set({ isLoading: false });
            }
          } else {
            set({ isLoading: false });
          }
        }
      } else {
        set({ isLoading: false });
      }
    } catch {
      set({ isLoading: false });
    }
  },

  login: async (email: string, password: string) => {
    const { accessToken, refreshToken } = await authApi.login({ email, password });
    await storage.set(TOKEN_KEY, accessToken);
    await storage.set(REFRESH_KEY, refreshToken);

    const user = await userApi.getMe(accessToken);
    set({ user, token: accessToken, refreshToken, isAuthenticated: true });
  },

  register: async (email: string, password: string, displayName: string) => {
    await authApi.register({ email, password, displayName });
    // After registration, log in automatically
    await get().login(email, password);
  },

  loginWithGoogle: async (idToken: string) => {
    const { accessToken, refreshToken } = await authApi.googleMobile({ idToken });
    await storage.set(TOKEN_KEY, accessToken);
    await storage.set(REFRESH_KEY, refreshToken);

    const user = await userApi.getMe(accessToken);
    set({ user, token: accessToken, refreshToken, isAuthenticated: true });
  },

  loginWithFacebook: async (accessToken: string) => {
    const { accessToken: token, refreshToken } = await authApi.facebookMobile({ accessToken });
    await storage.set(TOKEN_KEY, token);
    await storage.set(REFRESH_KEY, refreshToken);

    const user = await userApi.getMe(token);
    set({ user, token, refreshToken, isAuthenticated: true });
  },

  logout: async () => {
    const { token, refreshToken } = get();
    try {
      if (token && refreshToken) {
        await authApi.logout(refreshToken, token);
      }
    } catch {
      // Ignore errors on logout
    }
    await storage.remove(TOKEN_KEY);
    await storage.remove(REFRESH_KEY);
    set({ user: null, token: null, refreshToken: null, isAuthenticated: false });
  },

  refreshTokens: async () => {
    const { refreshToken } = get();
    if (!refreshToken) return false;

    try {
      const result = await authApi.refresh(refreshToken);
      await storage.set(TOKEN_KEY, result.accessToken);
      await storage.set(REFRESH_KEY, result.refreshToken);

      const user = await userApi.getMe(result.accessToken);
      set({
        user,
        token: result.accessToken,
        refreshToken: result.refreshToken,
        isAuthenticated: true,
        isLoading: false,
      });
      return true;
    } catch {
      await storage.remove(TOKEN_KEY);
      await storage.remove(REFRESH_KEY);
      set({ user: null, token: null, refreshToken: null, isAuthenticated: false, isLoading: false });
      return false;
    }
  },

  updateUser: (data: Partial<User>) => {
    const { user } = get();
    if (user) {
      set({ user: { ...user, ...data } });
    }
  },
}));
