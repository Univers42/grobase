import React from 'react';
import { View, StyleSheet, Image } from 'react-native';
import { Card, Text, IconButton, useTheme } from 'react-native-paper';

interface TrackCardProps {
  title: string;
  artist: string;
  albumCover?: string;
  duration?: number;
  isPlaying?: boolean;
  onPlay?: () => void;
  onAdd?: () => void;
  onRemove?: () => void;
  votes?: number;
  onVote?: () => void;
  hasVoted?: boolean;
  compact?: boolean;
}

function formatDuration(seconds: number): string {
  const mins = Math.floor(seconds / 60);
  const secs = seconds % 60;
  return `${mins}:${secs.toString().padStart(2, '0')}`;
}

export function TrackCard({
  title,
  artist,
  albumCover,
  duration,
  isPlaying,
  onPlay,
  onAdd,
  onRemove,
  votes,
  onVote,
  hasVoted,
  compact,
}: TrackCardProps) {
  const theme = useTheme();

  return (
    <Card
      style={[styles.card, compact && styles.cardCompact]}
      mode="outlined"
    >
      <View style={styles.row}>
        {albumCover && (
          <Image source={{ uri: albumCover }} style={[styles.cover, compact && styles.coverCompact]} />
        )}
        <View style={styles.info}>
          <Text
            variant={compact ? 'bodyMedium' : 'titleSmall'}
            numberOfLines={1}
            style={isPlaying ? { color: theme.colors.primary } : undefined}
          >
            {title}
          </Text>
          <Text variant="bodySmall" style={{ color: theme.colors.onSurfaceVariant }} numberOfLines={1}>
            {artist}
            {duration ? ` · ${formatDuration(duration)}` : ''}
          </Text>
        </View>
        <View style={styles.actions}>
          {onVote && (
            <View style={styles.voteContainer}>
              <IconButton
                icon={hasVoted ? 'thumb-up' : 'thumb-up-outline'}
                size={20}
                iconColor={hasVoted ? theme.colors.primary : undefined}
                onPress={onVote}
              />
              {votes !== undefined && (
                <Text variant="labelSmall" style={styles.voteCount}>
                  {votes}
                </Text>
              )}
            </View>
          )}
          {onPlay && (
            <IconButton
              icon={isPlaying ? 'pause-circle' : 'play-circle'}
              size={28}
              iconColor={theme.colors.primary}
              onPress={onPlay}
            />
          )}
          {onAdd && (
            <IconButton icon="plus" size={20} onPress={onAdd} />
          )}
          {onRemove && (
            <IconButton icon="close" size={20} onPress={onRemove} />
          )}
        </View>
      </View>
    </Card>
  );
}

const styles = StyleSheet.create({
  card: {
    marginHorizontal: 16,
    marginVertical: 4,
  },
  cardCompact: {
    marginHorizontal: 8,
    marginVertical: 2,
  },
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    padding: 8,
  },
  cover: {
    width: 48,
    height: 48,
    borderRadius: 4,
    marginRight: 12,
  },
  coverCompact: {
    width: 36,
    height: 36,
  },
  info: {
    flex: 1,
    justifyContent: 'center',
  },
  actions: {
    flexDirection: 'row',
    alignItems: 'center',
  },
  voteContainer: {
    alignItems: 'center',
    minWidth: 40,
  },
  voteCount: {
    marginTop: -8,
  },
});
