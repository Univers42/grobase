import React from 'react';
import { View, StyleSheet, Platform } from 'react-native';
import { Text, Surface, useTheme, IconButton } from 'react-native-paper';

interface MapMarkerCardProps {
  event: {
    id: string;
    name: string;
    participantCount: number;
    distance?: number;
    isLive?: boolean;
  };
  onPress: (eventId: string) => void;
  onNavigate?: (eventId: string) => void;
}

export function MapMarkerCard({
  event,
  onPress,
  onNavigate,
}: MapMarkerCardProps) {
  const theme = useTheme();

  const formatDistance = (meters?: number) => {
    if (!meters) return '';
    if (meters < 1000) return `${Math.round(meters)}m`;
    return `${(meters / 1000).toFixed(1)}km`;
  };

  return (
    <Surface
      style={[styles.card, event.isLive && styles.liveCard]}
      elevation={2}
    >
      <View style={styles.content} onTouchStart={() => onPress(event.id)}>
        {event.isLive && (
          <View style={styles.liveBadge}>
            <View style={styles.liveDot} />
            <Text variant="labelSmall" style={styles.liveText}>
              LIVE
            </Text>
          </View>
        )}
        <Text variant="titleSmall" numberOfLines={1}>
          {event.name}
        </Text>
        <View style={styles.meta}>
          <Text
            variant="bodySmall"
            style={{ color: theme.colors.onSurfaceVariant }}
          >
            {event.participantCount} listening
          </Text>
          {event.distance !== undefined && (
            <Text
              variant="bodySmall"
              style={{ color: theme.colors.onSurfaceVariant }}
            >
              · {formatDistance(event.distance)}
            </Text>
          )}
        </View>
      </View>
      {onNavigate && (
        <IconButton
          icon="directions"
          size={20}
          onPress={() => onNavigate(event.id)}
        />
      )}
    </Surface>
  );
}

const styles = StyleSheet.create({
  card: {
    flexDirection: 'row',
    alignItems: 'center',
    borderRadius: 12,
    padding: 12,
    minWidth: 200,
    ...Platform.select({
      ios: {
        shadowColor: '#000',
        shadowOffset: { width: 0, height: 2 },
        shadowOpacity: 0.1,
        shadowRadius: 4,
      },
      android: {
        elevation: 3,
      },
    }),
  },
  liveCard: {
    borderLeftWidth: 3,
    borderLeftColor: '#4CAF50',
  },
  content: {
    flex: 1,
  },
  liveBadge: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 4,
    marginBottom: 4,
  },
  liveDot: {
    width: 6,
    height: 6,
    borderRadius: 3,
    backgroundColor: '#4CAF50',
  },
  liveText: {
    color: '#4CAF50',
    fontWeight: '700',
    fontSize: 10,
  },
  meta: {
    flexDirection: 'row',
    gap: 0,
    marginTop: 2,
  },
});
