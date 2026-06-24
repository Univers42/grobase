import React from 'react';
import { View, StyleSheet } from 'react-native';
import { Card, Text, Chip, useTheme, IconButton } from 'react-native-paper';

interface EventCardProps {
  name: string;
  description?: string;
  licenseType: 'OPEN' | 'INVITED_ONLY' | 'GEO_TIME';
  participantCount: number;
  trackCount: number;
  startTime?: string;
  tags?: string[];
  onPress?: () => void;
  onJoin?: () => void;
  isParticipant?: boolean;
}

const LICENSE_ICONS = {
  OPEN: 'earth',
  INVITED_ONLY: 'lock',
  GEO_TIME: 'map-marker-radius',
};

const LICENSE_LABELS = {
  OPEN: 'Open',
  INVITED_ONLY: 'Invite Only',
  GEO_TIME: 'Geo-Restricted',
};

export function EventCard({
  name,
  description,
  licenseType,
  participantCount,
  trackCount,
  startTime,
  tags,
  onPress,
  onJoin,
  isParticipant,
}: EventCardProps) {
  const theme = useTheme();

  const formatDate = (dateStr: string) => {
    const date = new Date(dateStr);
    return date.toLocaleDateString(undefined, {
      month: 'short',
      day: 'numeric',
      hour: '2-digit',
      minute: '2-digit',
    });
  };

  return (
    <Card style={styles.card} mode="elevated" onPress={onPress}>
      <Card.Content>
        <View style={styles.header}>
          <View style={styles.titleRow}>
            <Text variant="titleMedium" numberOfLines={1} style={{ flex: 1 }}>
              {name}
            </Text>
            <Chip
              icon={LICENSE_ICONS[licenseType]}
              compact
              style={styles.licenseBadge}
              textStyle={{ fontSize: 11 }}
            >
              {LICENSE_LABELS[licenseType]}
            </Chip>
          </View>

          {description && (
            <Text
              variant="bodySmall"
              numberOfLines={2}
              style={{ color: theme.colors.onSurfaceVariant, marginTop: 4 }}
            >
              {description}
            </Text>
          )}
        </View>

        <View style={styles.meta}>
          <View style={styles.metaItem}>
            <IconButton icon="account-group" size={16} style={styles.metaIcon} />
            <Text variant="labelSmall">{participantCount}</Text>
          </View>
          <View style={styles.metaItem}>
            <IconButton icon="music-note" size={16} style={styles.metaIcon} />
            <Text variant="labelSmall">{trackCount} tracks</Text>
          </View>
          {startTime && (
            <View style={styles.metaItem}>
              <IconButton icon="clock-outline" size={16} style={styles.metaIcon} />
              <Text variant="labelSmall">{formatDate(startTime)}</Text>
            </View>
          )}
        </View>

        {tags && tags.length > 0 && (
          <View style={styles.tags}>
            {tags.slice(0, 4).map((tag) => (
              <Chip key={tag} compact style={styles.tag} textStyle={{ fontSize: 10 }}>
                {tag}
              </Chip>
            ))}
          </View>
        )}
      </Card.Content>

      {onJoin && (
        <Card.Actions>
          <Chip
            icon={isParticipant ? 'check' : 'plus'}
            onPress={onJoin}
            selected={isParticipant}
          >
            {isParticipant ? 'Joined' : 'Join'}
          </Chip>
        </Card.Actions>
      )}
    </Card>
  );
}

const styles = StyleSheet.create({
  card: {
    marginHorizontal: 16,
    marginVertical: 6,
  },
  header: {
    marginBottom: 8,
  },
  titleRow: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
  },
  licenseBadge: {
    marginLeft: 8,
  },
  meta: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 8,
  },
  metaItem: {
    flexDirection: 'row',
    alignItems: 'center',
  },
  metaIcon: {
    margin: 0,
    marginRight: -4,
  },
  tags: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    gap: 4,
    marginTop: 8,
  },
  tag: {
    height: 24,
  },
});
