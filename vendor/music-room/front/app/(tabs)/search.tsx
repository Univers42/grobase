import { useState, useCallback } from 'react';
import { View, StyleSheet, FlatList, Image } from 'react-native';
import { Searchbar, List, IconButton, Text, useTheme, ActivityIndicator } from 'react-native-paper';
import { musicApi } from '../../src/services';
import { useAuthStore, usePlayerStore } from '../../src/stores';

type Track = {
  id: number;
  title: string;
  artist: { name: string };
  album: { title: string; cover_medium: string };
  preview: string;
  duration: number;
};

export default function SearchScreen() {
  const theme = useTheme();
  const token = useAuthStore((s) => s.token);
  const { currentTrack, isPlaying, play, pause, resume } = usePlayerStore();

  const [query, setQuery] = useState('');
  const [tracks, setTracks] = useState<Track[]>([]);
  const [loading, setLoading] = useState(false);

  const handleSearch = useCallback(async () => {
    if (!query.trim() || !token) return;
    setLoading(true);
    try {
      const result = await musicApi.searchTracks(query.trim(), token);
      setTracks(result.data || []);
    } catch (err) {
      console.error('Search failed:', err);
    } finally {
      setLoading(false);
    }
  }, [query, token]);

  const handlePlay = async (track: Track) => {
    const isCurrentTrack = currentTrack?.deezerTrackId === track.id;

    if (isCurrentTrack && isPlaying) {
      await pause();
    } else if (isCurrentTrack && !isPlaying) {
      await resume();
    } else {
      await play({
        deezerTrackId: track.id,
        title: track.title,
        artist: track.artist.name,
        albumCover: track.album.cover_medium,
        previewUrl: track.preview,
      });
    }
  };

  const formatDuration = (seconds: number) => {
    const m = Math.floor(seconds / 60);
    const s = seconds % 60;
    return `${m}:${s.toString().padStart(2, '0')}`;
  };

  const renderTrack = ({ item }: { item: Track }) => {
    const isCurrentTrack = currentTrack?.deezerTrackId === item.id;
    const playing = isCurrentTrack && isPlaying;

    return (
      <List.Item
        title={item.title}
        description={`${item.artist.name} · ${formatDuration(item.duration)}`}
        titleStyle={{ color: isCurrentTrack ? theme.colors.primary : theme.colors.onSurface }}
        descriptionStyle={{ color: theme.colors.onSurfaceVariant }}
        left={() => (
          <Image
            source={{ uri: item.album.cover_medium }}
            style={styles.albumCover}
          />
        )}
        right={() => (
          <IconButton
            icon={playing ? 'pause-circle' : 'play-circle'}
            iconColor={theme.colors.primary}
            size={32}
            onPress={() => handlePlay(item)}
          />
        )}
        style={[
          styles.trackItem,
          isCurrentTrack && { backgroundColor: theme.colors.surfaceVariant },
        ]}
      />
    );
  };

  return (
    <View style={[styles.container, { backgroundColor: theme.colors.background }]}>
      <Searchbar
        placeholder="Search tracks, artists..."
        value={query}
        onChangeText={setQuery}
        onSubmitEditing={handleSearch}
        style={[styles.searchBar, { backgroundColor: theme.colors.surface }]}
      />

      {loading ? (
        <View style={styles.center}>
          <ActivityIndicator size="large" />
        </View>
      ) : tracks.length === 0 ? (
        <View style={styles.center}>
          <Text variant="bodyLarge" style={{ color: theme.colors.onSurfaceVariant }}>
            {query ? 'No results found' : 'Search for your favorite music'}
          </Text>
        </View>
      ) : (
        <FlatList
          data={tracks}
          keyExtractor={(item) => item.id.toString()}
          renderItem={renderTrack}
          contentContainerStyle={styles.list}
        />
      )}
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
  },
  searchBar: {
    margin: 16,
    elevation: 2,
  },
  center: {
    flex: 1,
    justifyContent: 'center',
    alignItems: 'center',
  },
  list: {
    paddingHorizontal: 8,
  },
  trackItem: {
    borderRadius: 8,
    marginVertical: 2,
    paddingLeft: 8,
  },
  albumCover: {
    width: 48,
    height: 48,
    borderRadius: 6,
    alignSelf: 'center',
  },
});
