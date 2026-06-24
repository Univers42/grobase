import React from 'react';
import { View, StyleSheet, ViewStyle, Image } from 'react-native';
import { Surface, Text, useTheme, IconButton } from 'react-native-paper';

interface NowPlayingCardProps {
  trackTitle: string;
  artist: string;
  albumCover?: string;
  isPlaying: boolean;
  progress: number;
  duration: string;
  elapsed: string;
  onPlayPause: () => void;
  onNext?: () => void;
  onPrevious?: () => void;
  style?: ViewStyle;
}

export const NowPlayingCard: React.FC<NowPlayingCardProps> = ({
  trackTitle,
  artist,
  albumCover,
  isPlaying,
  progress,
  duration,
  elapsed,
  onPlayPause,
  onNext,
  onPrevious,
  style,
}) => {
  const theme = useTheme();

  return (
    <Surface style={[styles.container, style]} elevation={3}>
      {albumCover && (
        <Image
          source={{ uri: albumCover }}
          style={styles.albumArt}
          accessibilityLabel={`Album cover for ${trackTitle}`}
        />
      )}

      <View style={styles.info}>
        <Text variant="titleMedium" numberOfLines={1} style={styles.title}>
          {trackTitle}
        </Text>
        <Text
          variant="bodyMedium"
          numberOfLines={1}
          style={{ color: theme.colors.onSurfaceVariant }}
        >
          {artist}
        </Text>
      </View>

      <View style={styles.progressContainer}>
        <View
          style={[
            styles.progressBar,
            { backgroundColor: theme.colors.surfaceVariant },
          ]}
        >
          <View
            style={[
              styles.progressFill,
              {
                backgroundColor: theme.colors.primary,
                width: `${Math.min(progress * 100, 100)}%`,
              },
            ]}
          />
        </View>
        <View style={styles.timeRow}>
          <Text variant="labelSmall" style={{ color: theme.colors.outline }}>
            {elapsed}
          </Text>
          <Text variant="labelSmall" style={{ color: theme.colors.outline }}>
            {duration}
          </Text>
        </View>
      </View>

      <View style={styles.controls}>
        {onPrevious && (
          <IconButton
            icon="skip-previous"
            onPress={onPrevious}
            size={28}
            accessibilityLabel="Previous track"
          />
        )}
        <IconButton
          icon={isPlaying ? 'pause-circle' : 'play-circle'}
          onPress={onPlayPause}
          size={48}
          iconColor={theme.colors.primary}
          accessibilityLabel={isPlaying ? 'Pause' : 'Play'}
        />
        {onNext && (
          <IconButton
            icon="skip-next"
            onPress={onNext}
            size={28}
            accessibilityLabel="Next track"
          />
        )}
      </View>
    </Surface>
  );
};

const styles = StyleSheet.create({
  container: {
    borderRadius: 16,
    padding: 20,
    alignItems: 'center',
    margin: 16,
  },
  albumArt: {
    width: 200,
    height: 200,
    borderRadius: 12,
    marginBottom: 16,
  },
  info: {
    alignItems: 'center',
    marginBottom: 16,
    width: '100%',
  },
  title: {
    fontWeight: '600',
    textAlign: 'center',
  },
  progressContainer: {
    width: '100%',
    marginBottom: 8,
  },
  progressBar: {
    height: 4,
    borderRadius: 2,
    overflow: 'hidden',
  },
  progressFill: {
    height: '100%',
    borderRadius: 2,
  },
  timeRow: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    marginTop: 4,
  },
  controls: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'center',
    gap: 8,
  },
});
