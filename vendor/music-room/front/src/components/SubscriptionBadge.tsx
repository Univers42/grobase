import React from 'react';
import { View, StyleSheet } from 'react-native';
import { Text, ProgressBar, useTheme, Chip } from 'react-native-paper';

interface SubscriptionBadgeProps {
  plan: 'free' | 'premium' | 'enterprise';
  expiresAt?: string;
  usagePercent?: number;
}

const PLAN_COLORS = {
  free: '#9E9E9E',
  premium: '#6C63FF',
  enterprise: '#FFD700',
};

const PLAN_LABELS = {
  free: 'Free',
  premium: 'Premium',
  enterprise: 'Enterprise',
};

export function SubscriptionBadge({ plan, expiresAt, usagePercent }: SubscriptionBadgeProps) {
  const theme = useTheme();
  const color = PLAN_COLORS[plan];

  const daysLeft = expiresAt
    ? Math.max(0, Math.ceil((new Date(expiresAt).getTime() - Date.now()) / 86400000))
    : null;

  return (
    <View style={styles.container}>
      <View style={styles.header}>
        <Chip
          mode="flat"
          style={[styles.chip, { backgroundColor: color }]}
          textStyle={styles.chipText}
        >
          {PLAN_LABELS[plan]}
        </Chip>
        {daysLeft !== null && (
          <Text variant="bodySmall" style={styles.expiry}>
            {daysLeft > 0 ? `${daysLeft} days left` : 'Expired'}
          </Text>
        )}
      </View>

      {usagePercent !== undefined && (
        <View style={styles.usage}>
          <View style={styles.usageHeader}>
            <Text variant="bodySmall">Usage</Text>
            <Text variant="bodySmall">{Math.round(usagePercent)}%</Text>
          </View>
          <ProgressBar
            progress={usagePercent / 100}
            color={usagePercent > 90 ? theme.colors.error : color}
            style={styles.progressBar}
          />
        </View>
      )}
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    padding: 12,
    borderRadius: 12,
    backgroundColor: 'rgba(108, 99, 255, 0.05)',
  },
  header: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
  },
  chip: {
    borderRadius: 16,
  },
  chipText: {
    color: '#fff',
    fontWeight: '600',
    fontSize: 12,
  },
  expiry: {
    opacity: 0.6,
  },
  usage: {
    marginTop: 12,
  },
  usageHeader: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    marginBottom: 4,
  },
  progressBar: {
    height: 6,
    borderRadius: 3,
  },
});
