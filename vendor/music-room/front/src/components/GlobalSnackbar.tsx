import React from 'react';
import { StyleSheet } from 'react-native';
import { Snackbar, useTheme } from 'react-native-paper';
import { useNotificationStore } from '../stores/notificationStore';

const TYPE_COLORS: Record<string, string> = {
  success: '#4CAF50',
  error: '#F44336',
  warning: '#FF9800',
  info: '#2196F3',
};

export function GlobalSnackbar() {
  const theme = useTheme();
  const messages = useNotificationStore((s) => s.messages);
  const dismiss = useNotificationStore((s) => s.dismiss);

  const current = messages[0];

  if (!current) return null;

  return (
    <Snackbar
      visible
      onDismiss={() => dismiss(current.id)}
      duration={current.duration || 3000}
      style={[
        styles.snackbar,
        { backgroundColor: TYPE_COLORS[current.type] || theme.colors.inverseSurface },
      ]}
      action={{
        label: 'Dismiss',
        textColor: '#fff',
        onPress: () => dismiss(current.id),
      }}
    >
      {current.text}
    </Snackbar>
  );
}

const styles = StyleSheet.create({
  snackbar: {
    marginBottom: 80,
  },
});
