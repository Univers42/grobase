import { useState, useEffect, useCallback } from 'react';
import { View, StyleSheet, FlatList, Image, Alert } from 'react-native';
import {
  Text,
  IconButton,
  Button,
  Chip,
  Divider,
  useTheme,
  ActivityIndicator,
} from 'react-native-paper';
import { useLocalSearchParams, Stack } from 'expo-router';
import { io, Socket } from 'socket.io-client';
import { eventApi, musicApi } from '../../src/services';
import { useAuthStore, usePlayerStore } from '../../src/stores';

type EventTrack = {
  deezerTrackId: number;
  title: string;
  artist: string;
  albumCover?: string;
  previewUrl?: string;
  voteCount: number;
  votedBy: string[];
};

type EventData = {
  _id: string;
  name: string;
  description?: string;
  visibility: string;
  licenseType: string;
  status: string;
  playlist: EventTrack[];
};

const API_URL = process.env.EXPO_PUBLIC_API_URL || 'http://localhost:3000';

export default function EventDetailScreen() {
  const theme = useTheme();
  const { id } = useLocalSearchParams<{ id: string }>();
  const token = useAuthStore((s) => s.token);
  const userId = useAuthStore((s) => s.user?._id);
  const { play, pause, resume, currentTrack, isPlaying } = usePlayerStore();

  const [event, setEvent] = useState<EventData | null>(null);
  const [loading, setLoading] = useState(true);
  const [socket, setSocket] = useState<Socket | null>(null);

  const fetchEvent = useCallback(async () => {
    if (!token || !id) return;
    try {
      const data = await eventApi.getById(id, token);
      setEvent(data);
    } catch (err) {
      console.error('Failed to fetch event:', err);
    } finally {
      setLoading(false);
    }
  }, [id, token]);

  useEffect(() => {
    fetchEvent();
  }, [fetchEvent]);

  // WebSocket connection for real-time votes
  useEffect(() => {
    if (!id) return;
    const ws = io(`${API_URL}/vote`, { transports: ['websocket'] });
    ws.on('connect', () => {
      ws.emit('join-event', { eventId: id });
    });
    ws.on('vote-received', () => fetchEvent());
    ws.on('track-suggested', () => fetchEvent());
    ws.on('playlist-updated', () => fetchEvent());
    setSocket(ws);

    return () => {
      ws.emit('leave-event', { eventId: id });
      ws.disconnect();
    };
  }, [id]);

  const handleVote = async (trackId: number) => {
    if (!token || !id) return;
    try {
      await eventApi.vote(id, trackId.toString(), token);
      fetchEvent();
    } catch (err) {
      Alert.alert('Error', 'Failed to vote');
    }
  };

  const handleRemoveVote = async (trackId: number) => {
    if (!token || !id) return;
    try {
      await eventApi.removeVote(id, trackId.toString(), token);
      fetchEvent();
    } catch (err) {
      Alert.alert('Error', 'Failed to remove vote');
    }
  };

  const handlePlay = async (track: EventTrack) => {
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

  if (loading) {
    return (
      <View style={[styles.center, { backgroundColor: theme.colors.background }]}>
        <ActivityIndicator size="large" />
      </View>
    );
  }

  if (!event) {
    return (
      <View style={[styles.center, { backgroundColor: theme.colors.background }]}>
        <Text>Event not found</Text>
      </View>
    );
  }

  const sortedPlaylist = [...(event.playlist || [])].sort((a, b) => b.voteCount - a.voteCount);

  const renderTrack = ({ item, index }: { item: EventTrack; index: number }) => {
    const hasVoted = item.votedBy.includes(userId || '');
    const isCurrent = currentTrack?.deezerTrackId === item.deezerTrackId;
    const playing = isCurrent && isPlaying;

    return (
      <View
        style={[
          styles.trackRow,
          { backgroundColor: isCurrent ? theme.colors.surfaceVariant : 'transparent' },
        ]}
      >
        <Text
          variant="titleLarge"
          style={[styles.rank, { color: index < 3 ? theme.colors.primary : theme.colors.onSurfaceVariant }]}
        >
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
        <View style={styles.voteSection}>
          <IconButton
            icon={hasVoted ? 'thumb-up' : 'thumb-up-outline'}
            iconColor={hasVoted ? theme.colors.primary : theme.colors.onSurfaceVariant}
            size={20}
            onPress={() => (hasVoted ? handleRemoveVote(item.deezerTrackId) : handleVote(item.deezerTrackId))}
          />
          <Text variant="labelMedium" style={{ color: theme.colors.primary }}>
            {item.voteCount}
          </Text>
        </View>
      </View>
    );
  };

  return (
    <View style={[styles.container, { backgroundColor: theme.colors.background }]}>
      <Stack.Screen options={{ title: event.name }} />

      <View style={styles.header}>
        <Text variant="headlineSmall" style={{ color: theme.colors.onBackground, fontWeight: '700' }}>
          {event.name}
        </Text>
        {event.description ? (
          <Text variant="bodyMedium" style={{ color: theme.colors.onSurfaceVariant, marginTop: 4 }}>
            {event.description}
          </Text>
        ) : null}
        <View style={styles.chips}>
          <Chip compact>{event.visibility}</Chip>
          <Chip compact>{event.licenseType}</Chip>
          <Chip compact>{event.status}</Chip>
        </View>
      </View>

      <Divider />

      <Text variant="titleMedium" style={[styles.sectionTitle, { color: theme.colors.onBackground }]}>
        Playlist ({sortedPlaylist.length} tracks)
      </Text>

      <FlatList
        data={sortedPlaylist}
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
  rank: { width: 28, textAlign: 'center', fontWeight: '700' },
  cover: { width: 40, height: 40, borderRadius: 4, marginRight: 10 },
  trackInfo: { flex: 1 },
  voteSection: { alignItems: 'center', minWidth: 48 },
});
