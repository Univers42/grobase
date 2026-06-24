import { useState, useEffect, useCallback } from 'react';
import { View, StyleSheet, FlatList, RefreshControl } from 'react-native';
import { Text, Card, Chip, FAB, useTheme, ActivityIndicator } from 'react-native-paper';
import { useRouter } from 'expo-router';
import { eventApi } from '../../src/services';
import { useAuthStore } from '../../src/stores';

type Event = {
  _id: string;
  name: string;
  description?: string;
  visibility: string;
  licenseType: string;
  status: string;
  createdBy: { _id: string; publicInfo?: { displayName?: string } };
  playlist: any[];
  createdAt: string;
};

export default function EventsScreen() {
  const theme = useTheme();
  const router = useRouter();
  const token = useAuthStore((s) => s.token);

  const [events, setEvents] = useState<Event[]>([]);
  const [loading, setLoading] = useState(true);
  const [refreshing, setRefreshing] = useState(false);

  const fetchEvents = useCallback(async () => {
    if (!token) return;
    try {
      const data = await eventApi.getAll(token);
      setEvents(Array.isArray(data) ? data : []);
    } catch (err) {
      console.error('Failed to fetch events:', err);
    } finally {
      setLoading(false);
      setRefreshing(false);
    }
  }, [token]);

  useEffect(() => {
    fetchEvents();
  }, [fetchEvents]);

  const onRefresh = useCallback(() => {
    setRefreshing(true);
    fetchEvents();
  }, [fetchEvents]);

  const getStatusColor = (status: string) => {
    switch (status) {
      case 'active': return theme.colors.primary;
      case 'ended': return theme.colors.error;
      default: return theme.colors.onSurfaceVariant;
    }
  };

  const renderEvent = ({ item }: { item: Event }) => (
    <Card
      style={[styles.card, { backgroundColor: theme.colors.surface }]}
      onPress={() => router.push(`/event/${item._id}`)}
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
            {item.visibility}
          </Chip>
          <Chip
            compact
            textStyle={{ fontSize: 11, color: getStatusColor(item.status) }}
            style={{ backgroundColor: theme.colors.surfaceVariant }}
          >
            {item.status}
          </Chip>
          <Chip
            compact
            textStyle={{ fontSize: 11 }}
            style={{ backgroundColor: theme.colors.surfaceVariant }}
          >
            🎵 {item.playlist?.length || 0} tracks
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
      {events.length === 0 ? (
        <View style={styles.center}>
          <Text variant="bodyLarge" style={{ color: theme.colors.onSurfaceVariant }}>
            No events yet. Create one!
          </Text>
        </View>
      ) : (
        <FlatList
          data={events}
          keyExtractor={(item) => item._id}
          renderItem={renderEvent}
          contentContainerStyle={styles.list}
          refreshControl={
            <RefreshControl refreshing={refreshing} onRefresh={onRefresh} />
          }
        />
      )}

      <FAB
        icon="plus"
        onPress={() => router.push('/event/create')}
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
