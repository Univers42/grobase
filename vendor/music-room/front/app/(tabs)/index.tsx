import { View, StyleSheet, FlatList } from 'react-native';
import { Text, Card, Button, useTheme } from 'react-native-paper';
import { useRouter } from 'expo-router';
import { useAuthStore } from '../../src/stores';

const quickActions = [
  { id: 'search', title: 'Search Music', icon: 'magnify', route: '/(tabs)/search' as const },
  { id: 'events', title: 'Browse Events', icon: 'calendar-music', route: '/(tabs)/events' as const },
  { id: 'playlists', title: 'My Playlists', icon: 'playlist-music', route: '/(tabs)/playlists' as const },
  { id: 'friends', title: 'Friends', icon: 'account-group', route: '/(tabs)/profile' as const },
];

export default function HomeScreen() {
  const theme = useTheme();
  const router = useRouter();
  const user = useAuthStore((s) => s.user);

  const displayName = user?.publicInfo?.displayName || user?.email?.split('@')[0] || 'User';

  return (
    <View style={[styles.container, { backgroundColor: theme.colors.background }]}>
      <View style={styles.header}>
        <Text variant="headlineMedium" style={{ color: theme.colors.onBackground }}>
          Welcome back,
        </Text>
        <Text variant="headlineLarge" style={{ color: theme.colors.primary, fontWeight: '700' }}>
          {displayName} 🎵
        </Text>
      </View>

      <Text variant="titleMedium" style={[styles.sectionTitle, { color: theme.colors.onBackground }]}>
        Quick Actions
      </Text>

      <FlatList
        data={quickActions}
        numColumns={2}
        keyExtractor={(item) => item.id}
        columnWrapperStyle={styles.row}
        contentContainerStyle={styles.grid}
        renderItem={({ item }) => (
          <Card
            style={[styles.card, { backgroundColor: theme.colors.surface }]}
            onPress={() => router.push(item.route)}
          >
            <Card.Content style={styles.cardContent}>
              <Text variant="headlineSmall" style={{ color: theme.colors.primary }}>
                {item.icon === 'magnify' ? '🔍' : 
                 item.icon === 'calendar-music' ? '🎉' :
                 item.icon === 'playlist-music' ? '📋' : '👥'}
              </Text>
              <Text variant="titleSmall" style={{ color: theme.colors.onSurface, textAlign: 'center' }}>
                {item.title}
              </Text>
            </Card.Content>
          </Card>
        )}
      />
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    padding: 16,
  },
  header: {
    marginBottom: 24,
    marginTop: 8,
  },
  sectionTitle: {
    marginBottom: 12,
    fontWeight: '600',
  },
  grid: {
    gap: 12,
  },
  row: {
    gap: 12,
  },
  card: {
    flex: 1,
    borderRadius: 12,
    elevation: 2,
  },
  cardContent: {
    alignItems: 'center',
    paddingVertical: 20,
    gap: 8,
  },
});
