import { useState, useEffect, useCallback } from 'react';
import { View, StyleSheet, FlatList, RefreshControl } from 'react-native';
import {
  Text,
  List,
  Button,
  Avatar,
  Divider,
  useTheme,
  ActivityIndicator,
} from 'react-native-paper';
import { Stack } from 'expo-router';
import { userApi, ApiError } from '../src/services';
import { useAuthStore } from '../src/stores';

type Friend = {
  _id: string;
  email: string;
  publicInfo?: { displayName?: string; avatar?: string };
};

type FriendRequest = {
  _id: string;
  requester: Friend;
  status: string;
};

export default function FriendsScreen() {
  const theme = useTheme();
  const token = useAuthStore((s) => s.token);

  const [friends, setFriends] = useState<Friend[]>([]);
  const [pending, setPending] = useState<FriendRequest[]>([]);
  const [loading, setLoading] = useState(true);
  const [refreshing, setRefreshing] = useState(false);

  const fetchData = useCallback(async () => {
    if (!token) return;
    try {
      const [friendsData, pendingData] = await Promise.all([
        userApi.getFriends(token),
        userApi.getPendingRequests(token),
      ]);
      setFriends(Array.isArray(friendsData) ? friendsData : []);
      setPending(Array.isArray(pendingData) ? pendingData : []);
    } catch (err) {
      console.error('Failed to fetch friends:', err);
    } finally {
      setLoading(false);
      setRefreshing(false);
    }
  }, [token]);

  useEffect(() => {
    fetchData();
  }, [fetchData]);

  const handleAccept = async (userId: string) => {
    if (!token) return;
    try {
      await userApi.acceptFriendRequest(userId, token);
      fetchData();
    } catch (err) {
      console.error('Failed to accept:', err);
    }
  };

  const handleRemove = async (userId: string) => {
    if (!token) return;
    try {
      await userApi.removeFriend(userId, token);
      fetchData();
    } catch (err) {
      console.error('Failed to remove:', err);
    }
  };

  if (loading) {
    return (
      <View style={[styles.center, { backgroundColor: theme.colors.background }]}>
        <ActivityIndicator size="large" />
      </View>
    );
  }

  return (
    <View style={[styles.container, { backgroundColor: theme.colors.background }]}>
      <Stack.Screen options={{ title: 'Friends' }} />

      {pending.length > 0 ? (
        <>
          <Text variant="titleMedium" style={[styles.section, { color: theme.colors.onBackground }]}>
            Pending Requests ({pending.length})
          </Text>
          {pending.map((req) => (
            <List.Item
              key={req._id}
              title={req.requester?.publicInfo?.displayName || req.requester?.email || 'Unknown'}
              left={() => (
                <Avatar.Text
                  size={40}
                  label={(req.requester?.publicInfo?.displayName || '?').slice(0, 2).toUpperCase()}
                />
              )}
              right={() => (
                <Button mode="contained" compact onPress={() => handleAccept(req.requester?._id)}>
                  Accept
                </Button>
              )}
            />
          ))}
          <Divider style={styles.divider} />
        </>
      ) : null}

      <Text variant="titleMedium" style={[styles.section, { color: theme.colors.onBackground }]}>
        Friends ({friends.length})
      </Text>

      {friends.length === 0 ? (
        <View style={styles.empty}>
          <Text variant="bodyLarge" style={{ color: theme.colors.onSurfaceVariant }}>
            No friends yet
          </Text>
        </View>
      ) : (
        <FlatList
          data={friends}
          keyExtractor={(item) => item._id}
          refreshControl={<RefreshControl refreshing={refreshing} onRefresh={() => { setRefreshing(true); fetchData(); }} />}
          renderItem={({ item }) => (
            <List.Item
              title={item.publicInfo?.displayName || item.email}
              description={item.email}
              left={() => (
                item.publicInfo?.avatar ? (
                  <Avatar.Image size={40} source={{ uri: item.publicInfo.avatar }} />
                ) : (
                  <Avatar.Text
                    size={40}
                    label={(item.publicInfo?.displayName || item.email).slice(0, 2).toUpperCase()}
                  />
                )
              )}
              right={() => (
                <Button
                  mode="text"
                  compact
                  textColor={theme.colors.error}
                  onPress={() => handleRemove(item._id)}
                >
                  Remove
                </Button>
              )}
            />
          )}
        />
      )}
    </View>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1 },
  center: { flex: 1, justifyContent: 'center', alignItems: 'center' },
  section: { paddingHorizontal: 16, paddingTop: 16, paddingBottom: 8, fontWeight: '600' },
  divider: { marginVertical: 8 },
  empty: { flex: 1, justifyContent: 'center', alignItems: 'center' },
});
