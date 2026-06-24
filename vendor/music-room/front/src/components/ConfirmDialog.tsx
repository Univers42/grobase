import React from 'react';
import { View, StyleSheet } from 'react-native';
import { Text, Button, useTheme } from 'react-native-paper';

interface ConfirmDialogContentProps {
  title: string;
  message: string;
  confirmLabel?: string;
  cancelLabel?: string;
  onConfirm: () => void;
  onCancel: () => void;
  destructive?: boolean;
  loading?: boolean;
}

export function ConfirmDialogContent({
  title,
  message,
  confirmLabel = 'Confirm',
  cancelLabel = 'Cancel',
  onConfirm,
  onCancel,
  destructive,
  loading,
}: ConfirmDialogContentProps) {
  const theme = useTheme();

  return (
    <View style={styles.container}>
      <Text variant="headlineSmall" style={styles.title}>
        {title}
      </Text>
      <Text variant="bodyMedium" style={{ color: theme.colors.onSurfaceVariant }}>
        {message}
      </Text>
      <View style={styles.actions}>
        <Button mode="text" onPress={onCancel} disabled={loading}>
          {cancelLabel}
        </Button>
        <Button
          mode="contained"
          onPress={onConfirm}
          loading={loading}
          disabled={loading}
          buttonColor={destructive ? theme.colors.error : undefined}
          textColor={destructive ? theme.colors.onError : undefined}
        >
          {confirmLabel}
        </Button>
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    padding: 24,
  },
  title: {
    marginBottom: 12,
  },
  actions: {
    flexDirection: 'row',
    justifyContent: 'flex-end',
    gap: 8,
    marginTop: 24,
  },
});
