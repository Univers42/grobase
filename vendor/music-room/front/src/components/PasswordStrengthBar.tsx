import React from 'react';
import { View, StyleSheet } from 'react-native';
import { ProgressBar, Text, useTheme } from 'react-native-paper';

interface PasswordStrengthBarProps {
  score: number;
  label: string;
  color: string;
  suggestions: string[];
  maxScore?: number;
}

export function PasswordStrengthBar({
  score,
  label,
  color,
  suggestions,
  maxScore = 6,
}: PasswordStrengthBarProps) {
  const theme = useTheme();
  const progress = score / maxScore;

  return (
    <View style={styles.container}>
      <View style={styles.header}>
        <Text variant="labelSmall">Password strength</Text>
        <Text variant="labelSmall" style={{ color }}>
          {label}
        </Text>
      </View>
      <ProgressBar
        progress={progress}
        color={color}
        style={styles.bar}
      />
      {suggestions.length > 0 && (
        <View style={styles.suggestions}>
          {suggestions.map((suggestion, i) => (
            <Text
              key={i}
              variant="bodySmall"
              style={{ color: theme.colors.onSurfaceVariant }}
            >
              • {suggestion}
            </Text>
          ))}
        </View>
      )}
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    marginVertical: 8,
  },
  header: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    marginBottom: 4,
  },
  bar: {
    height: 4,
    borderRadius: 2,
  },
  suggestions: {
    marginTop: 6,
    gap: 2,
  },
});
