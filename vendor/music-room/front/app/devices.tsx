import { useState, useEffect, useCallback } from 'react';
import { View, StyleSheet, FlatList, RefreshControl, Alert } from 'react-native';
import { Text, Card, Button, Chip, FAB, useTheme, ActivityIndicator } from 'react-native-paper';
import { Stack } from 'expo-router';
import { api, ApiError } from '../src/services';
import { useAuthStore } from '../src/stores';

type Device = {
  _id: string;
  name: string;
  platform: string;
  model?: string;
  osVersion?: string;
  isActive: boolean;
  lastSeenAt?: string;
};

export default function DevicesScreen() {
  const theme = useTheme();
  const token = useAuthStore((s) => s.token);

  const [devices, setDevices] = useState<Device[]>([]);
  const [loading, setLoading] = useState(true);
  const [refreshing, setRefreshing] = useState(false);

  const fetchDevices = useCallback(async () => {
    if (!token) return;
    try {
      const data = await api.get('/devices', token);
      setDevices(Array.isArray(data) ? data : []);
    } catch (err) {
      console.error('Failed to fetch devices:', err);
    } finally {
      setLoading(false);
      setRefreshing(false);
    }
  }, [token]);

  useEffect(() => {
    fetchDevices();
  }, [fetchDevices]);

  const handleRemove = async (deviceId: string) => {
    Alert.alert('Remove Device', 'This will deactivate the device and revoke delegations.', [
      { text: 'Cancel', style: 'cancel' },
      {
        text: 'Remove',
        style: 'destructive',
        onPress: async () => {
          if (!token) return;
          try {
            await api.delete(`/devices/${deviceId}`, token);
            fetchDevices();
          } catch (err) {
            Alert.alert('Error', 'Failed to remove device');
          }
        },
      },
    ]);
  };

  const getPlatformIcon = (platform: string) => {
    switch (platform) {
      case 'ios': return '🍎';
      case 'android': return '🤖';
      case 'web': return '🌐';
      case 'iot': return '📡';
      default: return '📱';
    }
  };

  if (loading) {
    return (
      <View style={[styles.center, { backgroundColor: theme.colors.background }]}>
        <ActivityIndicator size="large" />
      </View>
    );
  }

  return (
    <View style={[styles.container, { backgroundColor: theme.colors.background }]}>
      <Stack.Screen options={{ title: 'My Devices' }} />

      {devices.length === 0 ? (
        <View style={styles.center}>
          <Text variant="bodyLarge" style={{ color: theme.colors.onSurfaceVariant }}>
            No registered devices
          </Text>
        </View>
      ) : (
        <FlatList
          data={devices}
          keyExtractor={(item) => item._id}
          contentContainerStyle={styles.list}
          refreshControl={<RefreshControl refreshing={refreshing} onRefresh={() => { setRefreshing(true); fetchDevices(); }} />}
          renderItem={({ item }) => (
            <Card style={[styles.card, { backgroundColor: theme.colors.surface }]}>
              <Card.Content>
                <View style={styles.deviceHeader}>
                  <Text variant="titleMedium" style={{ color: theme.colors.onSurface }}>
                    {getPlatformIcon(item.platform)} {item.name}
                  </Text>
                  <Chip compact>{item.platform}</Chip>
                </View>
                {item.model ? (
                  <Text variant="bodySmall" style={{ color: theme.colors.onSurfaceVariant }}>
                    {item.model} · {item.osVersion || 'Unknown OS'}
                  </Text>
                ) : null}
                {item.lastSeenAt ? (
                  <Text variant="bodySmall" style={{ color: theme.colors.onSurfaceVariant, marginTop: 4 }}>
                    Last seen: {new Date(item.lastSeenAt).toLocaleString()}
                  </Text>
                ) : null}
              </Card.Content>
              <Card.Actions>
                <Button textColor={theme.colors.error} onPress={() => handleRemove(item._id)}>
                  Remove
                </Button>
              </Card.Actions>
            </Card>
          )}
        />
      )}
    </View>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1 },
  center: { flex: 1, justifyContent: 'center', alignItems: 'center' },
  list: { padding: 16, gap: 12 },
  card: { borderRadius: 12, elevation: 2 },
  deviceHeader: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center' },
});
