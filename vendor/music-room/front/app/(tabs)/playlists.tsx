import { useState, useEffect, useCallback } from 'react';
import { View, StyleSheet, FlatList, RefreshControl } from 'react-native';
import { Text, Card, Chip, FAB, useTheme, ActivityIndicator } from 'react-native-paper';
import { useRouter } from 'expo-router';
import { playlistApi } from '../../src/services';
import { useAuthStore } from '../../src/stores';

type Playlist = {
  _id: string;
  name: string;
  description?: string;
  visibility: string;
  licenseType: string;
  owner: { _id: string; publicInfo?: { displayName?: string } };
  tracks: any[];
  collaborators: string[];
  version: number;
  createdAt: string;
};

export default function PlaylistsScreen() {
  const theme = useTheme();
  const router = useRouter();
  const token = useAuthStore((s) => s.token);

  const [playlists, setPlaylists] = useState<Playlist[]>([]);
  const [loading, setLoading] = useState(true);
  const [refreshing, setRefreshing] = useState(false);

  const fetchPlaylists = useCallback(async () => {
    if (!token) return;
    try {
      const data = await playlistApi.getAll(token);
      setPlaylists(Array.isArray(data) ? data : []);
    } catch (err) {
      console.error('Failed to fetch playlists:', err);
    } finally {
      setLoading(false);
      setRefreshing(false);
    }
  }, [token]);

  useEffect(() => {
    fetchPlaylists();
  }, [fetchPlaylists]);

  const onRefresh = useCallback(() => {
    setRefreshing(true);
    fetchPlaylists();
  }, [fetchPlaylists]);

  const renderPlaylist = ({ item }: { item: Playlist }) => (
    <Card
      style={[styles.card, { backgroundColor: theme.colors.surface }]}
      onPress={() => router.push(`/playlist/${item._id}`)}
    >
      <Card.Content>
        <Text variant="titleMedium" style={{ color: theme.colors.onSurface, fontWeight: '600' }}>
          {item.name}
        </Text>
        {item.description ? (
          <Text
            variant="bodyMedium"
            numberOfLines={2}
            style={{ color: theme.colors.onSurfaceVariant, marginTop: 4 }}
          >
            {item.description}
          </Text>
        ) : null}
        <View style={styles.chips}>
          <Chip
            compact
            textStyle={{ fontSize: 11 }}
            style={{ backgroundColor: theme.colors.surfaceVariant }}
          >
            🎵 {item.tracks?.length || 0} tracks
          </Chip>
          <Chip
            compact
            textStyle={{ fontSize: 11 }}
            style={{ backgroundColor: theme.colors.surfaceVariant }}
          >
            👥 {(item.collaborators?.length || 0) + 1}
          </Chip>
          <Chip
            compact
            textStyle={{ fontSize: 11 }}
            style={{ backgroundColor: theme.colors.surfaceVariant }}
          >
            v{item.version}
          </Chip>
        </View>
      </Card.Content>
    </Card>
  );

  if (loading) {
    return (
      <View style={[styles.center, { backgroundColor: theme.colors.background }]}>
        <ActivityIndicator size="large" />
      </View>
    );
  }

  return (
    <View style={[styles.container, { backgroundColor: theme.colors.background }]}>
      {playlists.length === 0 ? (
        <View style={styles.center}>
          <Text variant="bodyLarge" style={{ color: theme.colors.onSurfaceVariant }}>
            No playlists yet. Create one!
          </Text>
        </View>
      ) : (
        <FlatList
          data={playlists}
          keyExtractor={(item) => item._id}
          renderItem={renderPlaylist}
          contentContainerStyle={styles.list}
          refreshControl={
            <RefreshControl refreshing={refreshing} onRefresh={onRefresh} />
          }
        />
      )}

      <FAB
        icon="plus"
        onPress={() => router.push('/playlist/create')}
        style={[styles.fab, { backgroundColor: theme.colors.primary }]}
        color={theme.colors.onPrimary}
      />
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
  },
  center: {
    flex: 1,
    justifyContent: 'center',
    alignItems: 'center',
  },
  list: {
    padding: 16,
    gap: 12,
  },
  card: {
    borderRadius: 12,
    elevation: 2,
  },
  chips: {
    flexDirection: 'row',
    gap: 8,
    marginTop: 8,
    flexWrap: 'wrap',
  },
  fab: {
    position: 'absolute',
    right: 16,
    bottom: 16,
    borderRadius: 16,
  },
});
