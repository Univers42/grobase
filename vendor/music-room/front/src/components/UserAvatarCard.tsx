import React from 'react';
import { View, StyleSheet, Image } from 'react-native';
import { Card, Text, IconButton, useTheme, Badge } from 'react-native-paper';

interface UserAvatarCardProps {
  displayName: string;
  username: string;
  avatarUrl?: string;
  bio?: string;
  onPress?: () => void;
  onAddFriend?: () => void;
  onRemoveFriend?: () => void;
  isFriend?: boolean;
  isPending?: boolean;
  showActions?: boolean;
}

export function UserAvatarCard({
  displayName,
  username,
  avatarUrl,
  bio,
  onPress,
  onAddFriend,
  onRemoveFriend,
  isFriend,
  isPending,
  showActions = true,
}: UserAvatarCardProps) {
  const theme = useTheme();

  const initials = displayName
    .split(' ')
    .map((n) => n[0])
    .join('')
    .toUpperCase()
    .slice(0, 2);

  return (
    <Card style={styles.card} mode="outlined" onPress={onPress}>
      <View style={styles.row}>
        {avatarUrl ? (
          <Image source={{ uri: avatarUrl }} style={styles.avatar} />
        ) : (
          <View style={[styles.avatar, styles.avatarPlaceholder, { backgroundColor: theme.colors.primaryContainer }]}>
            <Text variant="titleMedium" style={{ color: theme.colors.primary }}>
              {initials}
            </Text>
          </View>
        )}

        <View style={styles.info}>
          <Text variant="titleSmall" numberOfLines={1}>
            {displayName}
          </Text>
          <Text variant="bodySmall" style={{ color: theme.colors.onSurfaceVariant }}>
            @{username}
          </Text>
          {bio && (
            <Text
              variant="bodySmall"
              numberOfLines={1}
              style={{ color: theme.colors.onSurfaceVariant, marginTop: 2 }}
            >
              {bio}
            </Text>
          )}
        </View>

        {showActions && (
          <View style={styles.actions}>
            {isPending && (
              <Badge style={{ backgroundColor: theme.colors.tertiary }}>Pending</Badge>
            )}
            {isFriend && !onRemoveFriend && (
              <IconButton icon="check-circle" size={20} iconColor={theme.colors.primary} />
            )}
            {onAddFriend && !isFriend && !isPending && (
              <IconButton icon="account-plus" size={22} onPress={onAddFriend} />
            )}
            {onRemoveFriend && (
              <IconButton icon="account-remove" size={22} onPress={onRemoveFriend} />
            )}
          </View>
        )}
      </View>
    </Card>
  );
}

const styles = StyleSheet.create({
  card: {
    marginHorizontal: 16,
    marginVertical: 4,
  },
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    padding: 12,
  },
  avatar: {
    width: 44,
    height: 44,
    borderRadius: 22,
    marginRight: 12,
  },
  avatarPlaceholder: {
    justifyContent: 'center',
    alignItems: 'center',
  },
  info: {
    flex: 1,
  },
  actions: {
    flexDirection: 'row',
    alignItems: 'center',
  },
});
