import { View, StyleSheet, Image } from 'react-native';
import { Text, IconButton, ProgressBar, useTheme, Surface } from 'react-native-paper';
import { usePlayerStore } from '../stores';

export default function MiniPlayer() {
  const theme = useTheme();
  const { currentTrack, isPlaying, position, duration, pause, resume, stop } = usePlayerStore();

  if (!currentTrack) return null;

  const progress = duration > 0 ? position / duration : 0;

  return (
    <Surface style={[styles.container, { backgroundColor: theme.colors.surface }]} elevation={4}>
      <ProgressBar
        progress={progress}
        color={theme.colors.primary}
        style={styles.progress}
      />
      <View style={styles.content}>
        {currentTrack.albumCover ? (
          <Image source={{ uri: currentTrack.albumCover }} style={styles.cover} />
        ) : (
          <View style={[styles.cover, { backgroundColor: theme.colors.surfaceVariant }]} />
        )}
        <View style={styles.info}>
          <Text variant="bodyMedium" numberOfLines={1} style={{ color: theme.colors.onSurface }}>
            {currentTrack.title}
          </Text>
          <Text variant="bodySmall" numberOfLines={1} style={{ color: theme.colors.onSurfaceVariant }}>
            {currentTrack.artist}
          </Text>
        </View>
        <IconButton
          icon={isPlaying ? 'pause' : 'play'}
          onPress={isPlaying ? pause : resume}
          iconColor={theme.colors.primary}
          size={28}
        />
        <IconButton
          icon="close"
          onPress={stop}
          iconColor={theme.colors.onSurfaceVariant}
          size={20}
        />
      </View>
    </Surface>
  );
}

const styles = StyleSheet.create({
  container: {
    borderTopLeftRadius: 12,
    borderTopRightRadius: 12,
  },
  progress: {
    height: 2,
    borderRadius: 0,
  },
  content: {
    flexDirection: 'row',
    alignItems: 'center',
    padding: 8,
    paddingLeft: 12,
  },
  cover: {
    width: 40,
    height: 40,
    borderRadius: 6,
    marginRight: 10,
  },
  info: {
    flex: 1,
  },
});
