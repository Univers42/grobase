import React from 'react';
import { View, StyleSheet, ViewStyle } from 'react-native';
import { Surface, Text, useTheme } from 'react-native-paper';
import { MaterialCommunityIcons } from '@expo/vector-icons';

interface StatCardProps {
  icon: keyof typeof MaterialCommunityIcons.glyphMap;
  label: string;
  value: string | number;
  trend?: 'up' | 'down' | 'neutral';
  trendValue?: string;
  style?: ViewStyle;
}

export const StatCard: React.FC<StatCardProps> = ({
  icon,
  label,
  value,
  trend,
  trendValue,
  style,
}) => {
  const theme = useTheme();

  const trendColor =
    trend === 'up'
      ? '#4CAF50'
      : trend === 'down'
        ? '#F44336'
        : theme.colors.onSurfaceVariant;

  const trendIcon =
    trend === 'up' ? 'trending-up' : trend === 'down' ? 'trending-down' : 'minus';

  return (
    <Surface style={[styles.card, style]} elevation={1}>
      <View style={styles.header}>
        <MaterialCommunityIcons
          name={icon}
          size={24}
          color={theme.colors.primary}
        />
        {trend && trendValue && (
          <View style={[styles.trendBadge, { backgroundColor: trendColor + '20' }]}>
            <MaterialCommunityIcons
              name={trendIcon}
              size={12}
              color={trendColor}
            />
            <Text style={[styles.trendText, { color: trendColor }]}>
              {trendValue}
            </Text>
          </View>
        )}
      </View>

      <Text variant="headlineSmall" style={styles.value}>
        {value}
      </Text>
      <Text
        variant="bodySmall"
        style={{ color: theme.colors.onSurfaceVariant }}
      >
        {label}
      </Text>
    </Surface>
  );
};

const styles = StyleSheet.create({
  card: {
    padding: 16,
    borderRadius: 12,
    minWidth: 140,
  },
  header: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
    marginBottom: 12,
  },
  value: {
    fontWeight: '700',
    marginBottom: 4,
  },
  trendBadge: {
    flexDirection: 'row',
    alignItems: 'center',
    paddingHorizontal: 6,
    paddingVertical: 2,
    borderRadius: 8,
    gap: 2,
  },
  trendText: {
    fontSize: 11,
    fontWeight: '600',
  },
});
