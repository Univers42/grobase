import { useState, useEffect, useCallback } from 'react';
import { View, StyleSheet, FlatList, Image, Alert } from 'react-native';
import {
  Text,
  IconButton,
  Chip,
  Divider,
  useTheme,
  ActivityIndicator,
} from 'react-native-paper';
import { useLocalSearchParams, Stack } from 'expo-router';
import { io, Socket } from 'socket.io-client';
import { playlistApi } from '../../src/services';
import { useAuthStore, usePlayerStore } from '../../src/stores';

type PlaylistTrack = {
  deezerTrackId: number;
  title: string;
  artist: string;
  albumCover?: string;
  previewUrl?: string;
  addedBy: string;
  position: number;
};

type PlaylistData = {
  _id: string;
  name: string;
  description?: string;
  visibility: string;
  licenseType: string;
  owner: { _id: string; publicInfo?: { displayName?: string } };
  tracks: PlaylistTrack[];
  collaborators: string[];
  version: number;
};

const API_URL = process.env.EXPO_PUBLIC_API_URL || 'http://localhost:3000';

export default function PlaylistDetailScreen() {
  const theme = useTheme();
  const { id } = useLocalSearchParams<{ id: string }>();
  const token = useAuthStore((s) => s.token);
  const userId = useAuthStore((s) => s.user?._id);
  const { play, pause, resume, currentTrack, isPlaying } = usePlayerStore();

  const [playlist, setPlaylist] = useState<PlaylistData | null>(null);
  const [loading, setLoading] = useState(true);

  const fetchPlaylist = useCallback(async () => {
    if (!token || !id) return;
    try {
      const data = await playlistApi.getById(id, token);
      setPlaylist(data);
    } catch (err) {
      console.error('Failed to fetch playlist:', err);
    } finally {
      setLoading(false);
    }
  }, [id, token]);

  useEffect(() => {
    fetchPlaylist();
  }, [fetchPlaylist]);

  // WebSocket for real-time updates
  useEffect(() => {
    if (!id) return;
    const ws = io(`${API_URL}/playlist`, { transports: ['websocket'] });
    ws.on('connect', () => {
      ws.emit('join-playlist', { playlistId: id });
    });
    ws.on('track-added', () => fetchPlaylist());
    ws.on('track-removed', () => fetchPlaylist());
    ws.on('track-reordered', () => fetchPlaylist());
    ws.on('playlist-updated', () => fetchPlaylist());

    return () => {
      ws.emit('leave-playlist', { playlistId: id });
      ws.disconnect();
    };
  }, [id]);

  const handlePlay = async (track: PlaylistTrack) => {
    if (!track.previewUrl) return;
    const isCurrent = currentTrack?.deezerTrackId === track.deezerTrackId;
    if (isCurrent && isPlaying) {
      await pause();
    } else if (isCurrent) {
      await resume();
    } else {
      await play({
        deezerTrackId: track.deezerTrackId,
        title: track.title,
        artist: track.artist,
        albumCover: track.albumCover,
        previewUrl: track.previewUrl,
      });
    }
  };

  const handleRemoveTrack = async (deezerTrackId: number) => {
    if (!token || !id || !playlist) return;
    Alert.alert('Remove Track', 'Are you sure?', [
      { text: 'Cancel', style: 'cancel' },
      {
        text: 'Remove',
        style: 'destructive',
        onPress: async () => {
          try {
            await playlistApi.removeTrack(id, deezerTrackId, playlist.version, token);
            fetchPlaylist();
          } catch (err) {
            Alert.alert('Error', 'Failed to remove track');
          }
        },
      },
    ]);
  };

  if (loading) {
    return (
      <View style={[styles.center, { backgroundColor: theme.colors.background }]}>
        <ActivityIndicator size="large" />
      </View>
    );
  }

  if (!playlist) {
    return (
      <View style={[styles.center, { backgroundColor: theme.colors.background }]}>
        <Text>Playlist not found</Text>
      </View>
    );
  }

  const sortedTracks = [...(playlist.tracks || [])].sort((a, b) => a.position - b.position);
  const isOwner = playlist.owner?._id === userId;

  const renderTrack = ({ item, index }: { item: PlaylistTrack; index: number }) => {
    const isCurrent = currentTrack?.deezerTrackId === item.deezerTrackId;
    const playing = isCurrent && isPlaying;

    return (
      <View
        style={[
          styles.trackRow,
          { backgroundColor: isCurrent ? theme.colors.surfaceVariant : 'transparent' },
        ]}
      >
        <Text variant="bodyMedium" style={[styles.rank, { color: theme.colors.onSurfaceVariant }]}>
          {index + 1}
        </Text>
        {item.albumCover ? (
          <Image source={{ uri: item.albumCover }} style={styles.cover} />
        ) : (
          <View style={[styles.cover, { backgroundColor: theme.colors.surfaceVariant }]} />
        )}
        <View style={styles.trackInfo}>
          <Text variant="bodyLarge" style={{ color: theme.colors.onSurface }} numberOfLines={1}>
            {item.title}
          </Text>
          <Text variant="bodySmall" style={{ color: theme.colors.onSurfaceVariant }}>
            {item.artist}
          </Text>
        </View>
        <IconButton
          icon={playing ? 'pause' : 'play'}
          size={20}
          onPress={() => handlePlay(item)}
          disabled={!item.previewUrl}
        />
        {isOwner ? (
          <IconButton
            icon="close"
            size={18}
            iconColor={theme.colors.error}
            onPress={() => handleRemoveTrack(item.deezerTrackId)}
          />
        ) : null}
      </View>
    );
  };

  return (
    <View style={[styles.container, { backgroundColor: theme.colors.background }]}>
      <Stack.Screen options={{ title: playlist.name }} />

      <View style={styles.header}>
        <Text variant="headlineSmall" style={{ color: theme.colors.onBackground, fontWeight: '700' }}>
          {playlist.name}
        </Text>
        {playlist.description ? (
          <Text variant="bodyMedium" style={{ color: theme.colors.onSurfaceVariant, marginTop: 4 }}>
            {playlist.description}
          </Text>
        ) : null}
        <View style={styles.chips}>
          <Chip compact>{playlist.visibility}</Chip>
          <Chip compact>v{playlist.version}</Chip>
          <Chip compact>👥 {(playlist.collaborators?.length || 0) + 1}</Chip>
        </View>
      </View>

      <Divider />

      <Text variant="titleMedium" style={[styles.sectionTitle, { color: theme.colors.onBackground }]}>
        Tracks ({sortedTracks.length})
      </Text>

      <FlatList
        data={sortedTracks}
        keyExtractor={(item) => item.deezerTrackId.toString()}
        renderItem={renderTrack}
        contentContainerStyle={styles.trackList}
      />
    </View>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1 },
  center: { flex: 1, justifyContent: 'center', alignItems: 'center' },
  header: { padding: 16 },
  chips: { flexDirection: 'row', gap: 8, marginTop: 8 },
  sectionTitle: { paddingHorizontal: 16, paddingVertical: 8, fontWeight: '600' },
  trackList: { paddingHorizontal: 8 },
  trackRow: {
    flexDirection: 'row',
    alignItems: 'center',
    paddingVertical: 6,
    paddingHorizontal: 8,
    borderRadius: 8,
    marginVertical: 2,
  },
  rank: { width: 28, textAlign: 'center' },
  cover: { width: 40, height: 40, borderRadius: 4, marginRight: 10 },
  trackInfo: { flex: 1 },
});
