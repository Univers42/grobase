import { create } from 'zustand';
import { userApi } from '../services/endpoints';

interface Friend {
  _id: string;
  requester: any;
  recipient: any;
  status: 'PENDING' | 'ACCEPTED' | 'DECLINED' | 'BLOCKED';
  createdAt: string;
}

interface FriendState {
  friends: Friend[];
  pendingRequests: Friend[];
  loading: boolean;
  error: string | null;

  fetchFriends: () => Promise<void>;
  fetchPendingRequests: () => Promise<void>;
  sendFriendRequest: (userId: string) => Promise<void>;
  acceptRequest: (requestId: string) => Promise<void>;
  declineRequest: (requestId: string) => Promise<void>;
  removeFriend: (friendId: string) => Promise<void>;
  clearError: () => void;
}

export const useFriendStore = create<FriendState>((set) => ({
  friends: [],
  pendingRequests: [],
  loading: false,
  error: null,

  fetchFriends: async () => {
    set({ loading: true, error: null });
    try {
      const friends = await userApi.getFriends();
      set({ friends, loading: false });
    } catch (err: any) {
      set({ error: err.message, loading: false });
    }
  },

  fetchPendingRequests: async () => {
    set({ loading: true, error: null });
    try {
      const requests = await userApi.getPendingFriendRequests();
      set({ pendingRequests: requests, loading: false });
    } catch (err: any) {
      set({ error: err.message, loading: false });
    }
  },

  sendFriendRequest: async (userId: string) => {
    try {
      await userApi.sendFriendRequest(userId);
    } catch (err: any) {
      set({ error: err.message });
    }
  },

  acceptRequest: async (requestId: string) => {
    try {
      await userApi.acceptFriendRequest(requestId);
      set((state) => ({
        pendingRequests: state.pendingRequests.filter((r) => r._id !== requestId),
      }));
    } catch (err: any) {
      set({ error: err.message });
    }
  },

  declineRequest: async (requestId: string) => {
    try {
      await userApi.declineFriendRequest(requestId);
      set((state) => ({
        pendingRequests: state.pendingRequests.filter((r) => r._id !== requestId),
      }));
    } catch (err: any) {
      set({ error: err.message });
    }
  },

  removeFriend: async (friendId: string) => {
    try {
      await userApi.removeFriend(friendId);
      set((state) => ({
        friends: state.friends.filter((f) => f._id !== friendId),
      }));
    } catch (err: any) {
      set({ error: err.message });
    }
  },

  clearError: () => set({ error: null }),
}));
