import { useState } from 'react';
import { View, FlatList, StyleSheet } from 'react-native';
import {
  Searchbar,
  List,
  Avatar,
  Button,
  Text,
  useTheme,
  ActivityIndicator,
} from 'react-native-paper';
import { Stack } from 'expo-router';
import { useAuthStore } from '../src/stores/authStore';
import { userApi } from '../src/services/endpoints';
import { useNotificationStore } from '../src/stores/notificationStore';

export default function UserSearchScreen() {
  const theme = useTheme();
  const token = useAuthStore((s) => s.token)!;
  const show = useNotificationStore((s) => s.show);

  const [query, setQuery] = useState('');
  const [results, setResults] = useState<any[]>([]);
  const [loading, setLoading] = useState(false);
  const [sentRequests, setSentRequests] = useState<Set<string>>(new Set());

  const handleSearch = async () => {
    if (!query.trim()) return;
    setLoading(true);
    try {
      // Search by display name or email – assumes backend supports q param
      const data = await userApi.getProfile(query.trim(), token);
      setResults(data ? [data] : []);
    } catch {
      setResults([]);
    } finally {
      setLoading(false);
    }
  };

  const handleSendRequest = async (userId: string) => {
    try {
      await userApi.sendFriendRequest(userId, token);
      setSentRequests((prev) => new Set(prev).add(userId));
      show('Friend request sent!', 'success');
    } catch (err: any) {
      show(err.message || 'Failed to send request', 'error');
    }
  };

  const renderUser = ({ item }: { item: any }) => (
    <List.Item
      title={item.publicInfo?.displayName || item.displayName || 'User'}
      description={item.publicInfo?.bio || ''}
      left={() => (
        <Avatar.Text
          size={40}
          label={(item.publicInfo?.displayName || item.displayName || 'U').slice(0, 2).toUpperCase()}
          style={{ backgroundColor: theme.colors.primaryContainer }}
        />
      )}
      right={() =>
        sentRequests.has(item._id) ? (
          <Text style={{ color: theme.colors.primary, alignSelf: 'center' }}>Sent</Text>
        ) : (
          <Button
            mode="contained-tonal"
            compact
            onPress={() => handleSendRequest(item._id)}
            style={{ alignSelf: 'center' }}
          >
            Add Friend
          </Button>
        )
      }
    />
  );

  return (
    <View style={[styles.container, { backgroundColor: theme.colors.background }]}>
      <Stack.Screen options={{ title: 'Find Users', headerShown: true }} />

      <Searchbar
        placeholder="Search by user ID or email"
        value={query}
        onChangeText={setQuery}
        onSubmitEditing={handleSearch}
        style={styles.searchbar}
      />

      {loading && <ActivityIndicator style={styles.loader} />}

      <FlatList
        data={results}
        keyExtractor={(item) => item._id}
        renderItem={renderUser}
        contentContainerStyle={styles.list}
        ListEmptyComponent={
          !loading && query.trim() ? (
            <Text style={[styles.emptyText, { color: theme.colors.onSurfaceVariant }]}>
              No users found
            </Text>
          ) : null
        }
      />
    </View>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1 },
  searchbar: { margin: 16 },
  list: { paddingHorizontal: 8 },
  loader: { marginTop: 20 },
  emptyText: { textAlign: 'center', marginTop: 40 },
});
