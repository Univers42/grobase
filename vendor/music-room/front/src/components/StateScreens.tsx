import React from 'react';
import { View, StyleSheet } from 'react-native';
import { ActivityIndicator, Text, useTheme } from 'react-native-paper';

interface LoadingScreenProps {
  message?: string;
}

export function LoadingScreen({ message = 'Loading...' }: LoadingScreenProps) {
  const theme = useTheme();

  return (
    <View style={[styles.container, { backgroundColor: theme.colors.background }]}>
      <ActivityIndicator size="large" color={theme.colors.primary} />
      <Text style={[styles.text, { color: theme.colors.onSurfaceVariant }]}>
        {message}
      </Text>
    </View>
  );
}

interface EmptyStateProps {
  icon?: string;
  title: string;
  description?: string;
  action?: React.ReactNode;
}

export function EmptyState({ title, description, action }: EmptyStateProps) {
  const theme = useTheme();

  return (
    <View style={[styles.container, { backgroundColor: theme.colors.background }]}>
      <Text variant="headlineSmall" style={{ color: theme.colors.onSurface, textAlign: 'center' }}>
        {title}
      </Text>
      {description && (
        <Text
          variant="bodyMedium"
          style={{ color: theme.colors.onSurfaceVariant, textAlign: 'center', marginTop: 8 }}
        >
          {description}
        </Text>
      )}
      {action && <View style={styles.action}>{action}</View>}
    </View>
  );
}

interface ErrorDisplayProps {
  message: string;
  onRetry?: () => void;
}

export function ErrorDisplay({ message, onRetry }: ErrorDisplayProps) {
  const theme = useTheme();

  return (
    <View style={[styles.container, { backgroundColor: theme.colors.background }]}>
      <Text
        variant="bodyLarge"
        style={{ color: theme.colors.error, textAlign: 'center' }}
      >
        {message}
      </Text>
      {onRetry && (
        <Text
          variant="labelLarge"
          style={{ color: theme.colors.primary, marginTop: 16 }}
          onPress={onRetry}
        >
          Tap to retry
        </Text>
      )}
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    justifyContent: 'center',
    alignItems: 'center',
    padding: 24,
  },
  text: {
    marginTop: 16,
    fontSize: 16,
  },
  action: {
    marginTop: 24,
  },
});
