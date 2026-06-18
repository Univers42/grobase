import React from 'react';
import { View, StyleSheet, FlatList } from 'react-native';
import { Text, IconButton, Surface, useTheme } from 'react-native-paper';

interface Track {
  id: string;
  title: string;
  artist: string;
  duration?: number;
  votes?: number;
}

interface TrackListProps {
  tracks: Track[];
  onTrackPress?: (track: Track) => void;
  onVoteUp?: (trackId: string) => void;
  onVoteDown?: (trackId: string) => void;
  showVotes?: boolean;
  showIndex?: boolean;
  emptyMessage?: string;
}

function formatDuration(seconds?: number): string {
  if (!seconds) return '--:--';
  const mins = Math.floor(seconds / 60);
  const secs = seconds % 60;
  return `${mins}:${secs.toString().padStart(2, '0')}`;
}

function TrackItem({
  track,
  index,
  onPress,
  onVoteUp,
  onVoteDown,
  showVotes,
  showIndex,
}: {
  track: Track;
  index: number;
  onPress?: (track: Track) => void;
  onVoteUp?: (trackId: string) => void;
  onVoteDown?: (trackId: string) => void;
  showVotes?: boolean;
  showIndex?: boolean;
}) {
  const theme = useTheme();

  return (
    <Surface style={styles.trackItem} elevation={0}>
      {showIndex && (
        <Text variant="bodyMedium" style={styles.index}>
          {index + 1}
        </Text>
      )}
      <View style={styles.trackInfo}>
        <Text variant="bodyMedium" numberOfLines={1}>
          {track.title}
        </Text>
        <Text variant="bodySmall" style={{ color: theme.colors.onSurfaceVariant }}>
          {track.artist} · {formatDuration(track.duration)}
        </Text>
      </View>
      {showVotes && (
        <View style={styles.voteContainer}>
          <IconButton icon="chevron-up" size={18} onPress={() => onVoteUp?.(track.id)} />
          <Text variant="bodySmall" style={styles.voteCount}>
            {track.votes ?? 0}
          </Text>
          <IconButton icon="chevron-down" size={18} onPress={() => onVoteDown?.(track.id)} />
        </View>
      )}
      <IconButton icon="play-circle-outline" size={24} onPress={() => onPress?.(track)} />
    </Surface>
  );
}

export function TrackList({
  tracks,
  onTrackPress,
  onVoteUp,
  onVoteDown,
  showVotes = false,
  showIndex = false,
  emptyMessage = 'No tracks',
}: TrackListProps) {
  if (tracks.length === 0) {
    return (
      <View style={styles.emptyContainer}>
        <Text variant="bodyMedium" style={styles.emptyText}>
          {emptyMessage}
        </Text>
      </View>
    );
  }

  return (
    <FlatList
      data={tracks}
      keyExtractor={(item) => item.id}
      renderItem={({ item, index }) => (
        <TrackItem
          track={item}
          index={index}
          onPress={onTrackPress}
          onVoteUp={onVoteUp}
          onVoteDown={onVoteDown}
          showVotes={showVotes}
          showIndex={showIndex}
        />
      )}
      ItemSeparatorComponent={() => <View style={styles.separator} />}
    />
  );
}

const styles = StyleSheet.create({
  trackItem: {
    flexDirection: 'row',
    alignItems: 'center',
    paddingVertical: 8,
    paddingHorizontal: 12,
  },
  index: {
    width: 24,
    textAlign: 'center',
    opacity: 0.5,
  },
  trackInfo: {
    flex: 1,
    marginLeft: 8,
  },
  voteContainer: {
    alignItems: 'center',
    minWidth: 40,
  },
  voteCount: {
    fontWeight: '600',
  },
  separator: {
    height: 1,
    backgroundColor: 'rgba(0,0,0,0.06)',
    marginLeft: 44,
  },
  emptyContainer: {
    padding: 32,
    alignItems: 'center',
  },
  emptyText: {
    opacity: 0.5,
  },
});
