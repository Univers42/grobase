import React from 'react';
import { View, StyleSheet, Image } from 'react-native';
import { Text, Button, Surface, useTheme } from 'react-native-paper';

interface ParticipantListItemProps {
  user: {
    id: string;
    username: string;
    avatarUrl?: string;
    role?: string;
  };
  isOwner?: boolean;
  canRemove?: boolean;
  onRemove?: (userId: string) => void;
  onPress?: (userId: string) => void;
}

export function ParticipantListItem({
  user,
  isOwner = false,
  canRemove = false,
  onRemove,
  onPress,
}: ParticipantListItemProps) {
  const theme = useTheme();

  return (
    <Surface style={styles.container} elevation={0} onTouchStart={() => onPress?.(user.id)}>
      {user.avatarUrl ? (
        <Image source={{ uri: user.avatarUrl }} style={styles.avatar} />
      ) : (
        <View style={[styles.avatar, styles.placeholderAvatar]}>
          <Text variant="titleMedium" style={styles.avatarText}>
            {user.username.charAt(0).toUpperCase()}
          </Text>
        </View>
      )}

      <View style={styles.info}>
        <View style={styles.nameRow}>
          <Text variant="bodyMedium" style={styles.username}>
            {user.username}
          </Text>
          {isOwner && (
            <View style={[styles.badge, { backgroundColor: theme.colors.primary }]}>
              <Text variant="labelSmall" style={styles.badgeText}>
                Owner
              </Text>
            </View>
          )}
        </View>
        {user.role && (
          <Text variant="bodySmall" style={{ color: theme.colors.onSurfaceVariant }}>
            {user.role}
          </Text>
        )}
      </View>

      {canRemove && (
        <Button
          mode="text"
          compact
          textColor={theme.colors.error}
          onPress={() => onRemove?.(user.id)}
        >
          Remove
        </Button>
      )}
    </Surface>
  );
}

const styles = StyleSheet.create({
  container: {
    flexDirection: 'row',
    alignItems: 'center',
    paddingVertical: 10,
    paddingHorizontal: 16,
  },
  avatar: {
    width: 40,
    height: 40,
    borderRadius: 20,
  },
  placeholderAvatar: {
    backgroundColor: '#6C63FF',
    justifyContent: 'center',
    alignItems: 'center',
  },
  avatarText: {
    color: '#fff',
    fontWeight: '600',
  },
  info: {
    flex: 1,
    marginLeft: 12,
  },
  nameRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 8,
  },
  username: {
    fontWeight: '500',
  },
  badge: {
    paddingHorizontal: 8,
    paddingVertical: 2,
    borderRadius: 10,
  },
  badgeText: {
    color: '#fff',
    fontSize: 10,
  },
});
