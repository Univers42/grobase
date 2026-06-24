import React from 'react';
import { View, StyleSheet, ScrollView } from 'react-native';
import { Text, Card, useTheme, Avatar, Chip, Button } from 'react-native-paper';

interface FriendRequestCardProps {
  request: {
    id: string;
    from: {
      id: string;
      username: string;
      avatarUrl?: string;
    };
    createdAt: string;
    mutualFriends?: number;
  };
  onAccept: (requestId: string) => void;
  onReject: (requestId: string) => void;
}

export function FriendRequestCard({
  request,
  onAccept,
  onReject,
}: FriendRequestCardProps) {
  const theme = useTheme();
  const { from } = request;

  const timeAgo = getTimeAgo(request.createdAt);

  return (
    <Card style={styles.card} mode="outlined">
      <Card.Content style={styles.content}>
        <View style={styles.userInfo}>
          {from.avatarUrl ? (
            <Avatar.Image size={48} source={{ uri: from.avatarUrl }} />
          ) : (
            <Avatar.Text
              size={48}
              label={from.username.charAt(0).toUpperCase()}
              style={{ backgroundColor: theme.colors.primary }}
            />
          )}
          <View style={styles.textInfo}>
            <Text variant="titleSmall">{from.username}</Text>
            <Text
              variant="bodySmall"
              style={{ color: theme.colors.onSurfaceVariant }}
            >
              {timeAgo}
            </Text>
            {request.mutualFriends !== undefined && request.mutualFriends > 0 && (
              <Chip
                compact
                mode="outlined"
                style={styles.mutualChip}
                textStyle={styles.mutualChipText}
              >
                {request.mutualFriends} mutual friend
                {request.mutualFriends > 1 ? 's' : ''}
              </Chip>
            )}
          </View>
        </View>

        <View style={styles.actions}>
          <Button
            mode="contained"
            compact
            onPress={() => onAccept(request.id)}
            style={styles.acceptBtn}
          >
            Accept
          </Button>
          <Button
            mode="outlined"
            compact
            onPress={() => onReject(request.id)}
          >
            Decline
          </Button>
        </View>
      </Card.Content>
    </Card>
  );
}

function getTimeAgo(dateStr: string): string {
  const diff = Date.now() - new Date(dateStr).getTime();
  const minutes = Math.floor(diff / 60000);
  const hours = Math.floor(minutes / 60);
  const days = Math.floor(hours / 24);

  if (days > 0) return `${days}d ago`;
  if (hours > 0) return `${hours}h ago`;
  if (minutes > 0) return `${minutes}m ago`;
  return 'Just now';
}

const styles = StyleSheet.create({
  card: {
    marginHorizontal: 16,
    marginVertical: 6,
  },
  content: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
  },
  userInfo: {
    flexDirection: 'row',
    alignItems: 'center',
    flex: 1,
  },
  textInfo: {
    marginLeft: 12,
    flex: 1,
  },
  mutualChip: {
    marginTop: 4,
    alignSelf: 'flex-start',
    height: 24,
  },
  mutualChipText: {
    fontSize: 10,
  },
  actions: {
    flexDirection: 'row',
    gap: 8,
  },
  acceptBtn: {
    minWidth: 80,
  },
});
