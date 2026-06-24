import React from 'react';
import { View, StyleSheet, ViewStyle } from 'react-native';
import { Text, useTheme, Avatar, Chip, TouchableRipple } from 'react-native-paper';
import { MaterialCommunityIcons } from '@expo/vector-icons';

interface NotificationItemProps {
  type: 'friend_request' | 'event_invite' | 'playlist_update' | 'vote' | 'system';
  title: string;
  message: string;
  timestamp: string;
  isRead: boolean;
  avatarUri?: string;
  onPress?: () => void;
  style?: ViewStyle;
}

const typeIcons: Record<string, keyof typeof MaterialCommunityIcons.glyphMap> = {
  friend_request: 'account-plus',
  event_invite: 'calendar-plus',
  playlist_update: 'playlist-music',
  vote: 'thumb-up',
  system: 'bell',
};

const typeColors: Record<string, string> = {
  friend_request: '#2196F3',
  event_invite: '#FF9800',
  playlist_update: '#4CAF50',
  vote: '#9C27B0',
  system: '#607D8B',
};

export const NotificationItem: React.FC<NotificationItemProps> = ({
  type,
  title,
  message,
  timestamp,
  isRead,
  avatarUri,
  onPress,
  style,
}) => {
  const theme = useTheme();
  const iconName = typeIcons[type] || 'bell';
  const iconColor = typeColors[type] || theme.colors.primary;

  return (
    <TouchableRipple
      onPress={onPress}
      style={[
        styles.container,
        !isRead && { backgroundColor: theme.colors.primaryContainer + '30' },
        style,
      ]}
      accessibilityLabel={`${title}: ${message}`}
      accessibilityRole="button"
    >
      <View style={styles.content}>
        <View style={styles.iconContainer}>
          {avatarUri ? (
            <Avatar.Image size={40} source={{ uri: avatarUri }} />
          ) : (
            <Avatar.Icon
              size={40}
              icon={iconName}
              style={{ backgroundColor: iconColor + '20' }}
              color={iconColor}
            />
          )}
          {!isRead && <View style={[styles.unreadDot, { backgroundColor: theme.colors.primary }]} />}
        </View>

        <View style={styles.textContainer}>
          <Text
            variant="bodyMedium"
            style={[styles.title, !isRead && styles.unreadTitle]}
            numberOfLines={1}
          >
            {title}
          </Text>
          <Text
            variant="bodySmall"
            style={{ color: theme.colors.onSurfaceVariant }}
            numberOfLines={2}
          >
            {message}
          </Text>
          <Text
            variant="labelSmall"
            style={[styles.timestamp, { color: theme.colors.outline }]}
          >
            {timestamp}
          </Text>
        </View>
      </View>
    </TouchableRipple>
  );
};

const styles = StyleSheet.create({
  container: {
    paddingHorizontal: 16,
    paddingVertical: 12,
  },
  content: {
    flexDirection: 'row',
    alignItems: 'flex-start',
  },
  iconContainer: {
    position: 'relative',
    marginRight: 12,
  },
  unreadDot: {
    position: 'absolute',
    top: 0,
    right: 0,
    width: 10,
    height: 10,
    borderRadius: 5,
    borderWidth: 2,
    borderColor: 'white',
  },
  textContainer: {
    flex: 1,
  },
  title: {
    marginBottom: 2,
  },
  unreadTitle: {
    fontWeight: '600',
  },
  timestamp: {
    marginTop: 4,
  },
});
