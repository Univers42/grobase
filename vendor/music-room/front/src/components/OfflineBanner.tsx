import React from 'react';
import { View, StyleSheet } from 'react-native';
import { Text, useTheme, IconButton } from 'react-native-paper';
import { useOfflineSync } from '../hooks';

/**
 * Persistent banner showing offline status and pending sync count.
 * Renders only when device is offline or has pending actions.
 */
export function OfflineBanner() {
  const theme = useTheme();
  const { isOnline, isSyncing, pendingCount, syncNow } = useOfflineSync();

  if (isOnline && pendingCount === 0) return null;

  const bgColor = !isOnline ? theme.colors.errorContainer : theme.colors.tertiaryContainer;
  const textColor = !isOnline ? theme.colors.onErrorContainer : theme.colors.onTertiaryContainer;

  return (
    <View style={[styles.banner, { backgroundColor: bgColor }]}>
      <View style={styles.content}>
        <Text variant="labelLarge" style={{ color: textColor }}>
          {!isOnline
            ? '📶 Offline — changes will be saved locally'
            : `🔄 ${pendingCount} pending change${pendingCount > 1 ? 's' : ''}`}
        </Text>
        {isSyncing && (
          <Text variant="bodySmall" style={{ color: textColor }}>
            Syncing...
          </Text>
        )}
      </View>
      {isOnline && pendingCount > 0 && !isSyncing && (
        <IconButton
          icon="sync"
          iconColor={textColor}
          size={20}
          onPress={syncNow}
        />
      )}
    </View>
  );
}

const styles = StyleSheet.create({
  banner: {
    flexDirection: 'row',
    alignItems: 'center',
    paddingHorizontal: 16,
    paddingVertical: 8,
  },
  content: {
    flex: 1,
  },
});
