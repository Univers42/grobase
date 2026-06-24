import React from 'react';
import { View, StyleSheet, Animated } from 'react-native';
import { ActivityIndicator, Text, useTheme } from 'react-native-paper';

interface SplashScreenProps {
  message?: string;
}

export function SplashScreen({ message = 'Loading...' }: SplashScreenProps) {
  const theme = useTheme();

  return (
    <View style={[styles.container, { backgroundColor: theme.colors.background }]}>
      <Text variant="headlineLarge" style={[styles.title, { color: theme.colors.primary }]}>
        🎵 Music Room
      </Text>
      <ActivityIndicator size="large" color={theme.colors.primary} style={styles.spinner} />
      <Text variant="bodyMedium" style={{ color: theme.colors.onSurfaceVariant }}>
        {message}
      </Text>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    justifyContent: 'center',
    alignItems: 'center',
  },
  title: {
    fontWeight: 'bold',
    marginBottom: 32,
  },
  spinner: {
    marginBottom: 16,
  },
});
