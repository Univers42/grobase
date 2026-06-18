import React from 'react';
import { View, StyleSheet, Image } from 'react-native';
import { Card, Text, Chip, IconButton, useTheme } from 'react-native-paper';

interface PlaylistCardProps {
  name: string;
  description?: string;
  trackCount: number;
  collaboratorCount: number;
  visibility: 'PUBLIC' | 'FRIENDS_ONLY' | 'PRIVATE';
  collaborationType: 'OPEN' | 'INVITE_ONLY' | 'VOTE_TO_ADD';
  ownerName: string;
  coverUrl?: string;
  tags?: string[];
  onPress?: () => void;
}

const VISIBILITY_ICONS = {
  PUBLIC: 'earth',
  FRIENDS_ONLY: 'account-group',
  PRIVATE: 'lock',
};

const COLLAB_LABELS = {
  OPEN: 'Open Collab',
  INVITE_ONLY: 'Invite Only',
  VOTE_TO_ADD: 'Vote to Add',
};

export function PlaylistCard({
  name,
  description,
  trackCount,
  collaboratorCount,
  visibility,
  collaborationType,
  ownerName,
  coverUrl,
  tags,
  onPress,
}: PlaylistCardProps) {
  const theme = useTheme();

  return (
    <Card style={styles.card} mode="elevated" onPress={onPress}>
      <View style={styles.content}>
        {coverUrl ? (
          <Image source={{ uri: coverUrl }} style={styles.cover} />
        ) : (
          <View style={[styles.cover, styles.coverPlaceholder, { backgroundColor: theme.colors.primaryContainer }]}>
            <IconButton icon="music-note-plus" size={28} iconColor={theme.colors.primary} />
          </View>
        )}

        <View style={styles.info}>
          <Text variant="titleSmall" numberOfLines={1}>
            {name}
          </Text>
          <Text variant="bodySmall" style={{ color: theme.colors.onSurfaceVariant }}>
            by {ownerName} · {trackCount} tracks
          </Text>

          {description && (
            <Text
              variant="bodySmall"
              numberOfLines={1}
              style={{ color: theme.colors.onSurfaceVariant, marginTop: 2 }}
            >
              {description}
            </Text>
          )}

          <View style={styles.badges}>
            <Chip
              icon={VISIBILITY_ICONS[visibility]}
              compact
              style={styles.badge}
              textStyle={{ fontSize: 10 }}
            >
              {visibility.replace('_', ' ')}
            </Chip>
            <Chip compact style={styles.badge} textStyle={{ fontSize: 10 }}>
              {COLLAB_LABELS[collaborationType]}
            </Chip>
          </View>
        </View>
      </View>
    </Card>
  );
}

const styles = StyleSheet.create({
  card: {
    marginHorizontal: 16,
    marginVertical: 6,
  },
  content: {
    flexDirection: 'row',
    padding: 12,
  },
  cover: {
    width: 64,
    height: 64,
    borderRadius: 8,
    marginRight: 12,
  },
  coverPlaceholder: {
    justifyContent: 'center',
    alignItems: 'center',
  },
  info: {
    flex: 1,
    justifyContent: 'center',
  },
  badges: {
    flexDirection: 'row',
    gap: 4,
    marginTop: 6,
  },
  badge: {
    height: 24,
  },
});
