import { useState, useEffect, useCallback } from 'react';
import { View, FlatList, StyleSheet, RefreshControl } from 'react-native';
import {
  Text,
  Card,
  Button,
  useTheme,
  Chip,
  Divider,
  Portal,
  Dialog,
  TextInput,
  SegmentedButtons,
  Checkbox,
} from 'react-native-paper';
import { Stack } from 'expo-router';
import { delegationApi } from '../src/services/endpoints';
import { useAuthStore } from '../src/stores/authStore';
import { useNotificationStore } from '../src/stores/notificationStore';

const PERMISSION_OPTIONS = [
  { key: 'playback_control', label: 'Playback' },
  { key: 'playlist_edit', label: 'Playlist Edit' },
  { key: 'volume_control', label: 'Volume' },
  { key: 'queue_manage', label: 'Queue' },
];

export default function DelegationScreen() {
  const theme = useTheme();
  const token = useAuthStore((s) => s.token)!;
  const show = useNotificationStore((s) => s.show);

  const [delegations, setDelegations] = useState<any[]>([]);
  const [loading, setLoading] = useState(true);
  const [dialogVisible, setDialogVisible] = useState(false);
  const [delegateId, setDelegateId] = useState('');
  const [targetDeviceId, setTargetDeviceId] = useState('');
  const [selectedPermissions, setSelectedPermissions] = useState<string[]>([]);

  const fetchDelegations = useCallback(async () => {
    setLoading(true);
    try {
      const data = await delegationApi.getMyDelegations(token);
      setDelegations(data as any[]);
    } catch (err: any) {
      show(err.message || 'Failed to load delegations', 'error');
    } finally {
      setLoading(false);
    }
  }, [token]);

  useEffect(() => {
    fetchDelegations();
  }, []);

  const handleCreate = async () => {
    if (!delegateId.trim() || !targetDeviceId.trim() || selectedPermissions.length === 0) {
      show('Please fill all fields and select at least one permission', 'warning');
      return;
    }
    try {
      await delegationApi.createDelegation(
        {
          delegateId: delegateId.trim(),
          targetDeviceId: targetDeviceId.trim(),
          permissions: selectedPermissions,
        },
        token,
      );
      show('Delegation created', 'success');
      setDialogVisible(false);
      setDelegateId('');
      setTargetDeviceId('');
      setSelectedPermissions([]);
      fetchDelegations();
    } catch (err: any) {
      show(err.message || 'Failed to create delegation', 'error');
    }
  };

  const handleAccept = async (id: string) => {
    try {
      await delegationApi.acceptDelegation(id, token);
      show('Delegation accepted', 'success');
      fetchDelegations();
    } catch (err: any) {
      show(err.message, 'error');
    }
  };

  const handleRevoke = async (id: string) => {
    try {
      await delegationApi.revokeDelegation(id, token);
      show('Delegation revoked', 'success');
      fetchDelegations();
    } catch (err: any) {
      show(err.message, 'error');
    }
  };

  const togglePermission = (key: string) => {
    setSelectedPermissions((prev) =>
      prev.includes(key) ? prev.filter((p) => p !== key) : [...prev, key],
    );
  };

  const getStatusColor = (status: string) => {
    switch (status) {
      case 'active': return theme.colors.primary;
      case 'pending': return theme.colors.tertiary;
      case 'revoked': return theme.colors.error;
      case 'expired': return theme.colors.onSurfaceVariant;
      default: return theme.colors.outline;
    }
  };

  const renderDelegation = ({ item }: { item: any }) => (
    <Card style={styles.card} mode="outlined">
      <Card.Content>
        <View style={styles.headerRow}>
          <Text variant="titleMedium">{item.delegate?.displayName || item.delegate}</Text>
          <Chip
            compact
            textStyle={{ color: '#fff', fontSize: 11 }}
            style={{ backgroundColor: getStatusColor(item.status) }}
          >
            {item.status}
          </Chip>
        </View>

        <Text variant="bodySmall" style={{ color: theme.colors.onSurfaceVariant, marginTop: 4 }}>
          Device: {item.targetDevice?.name || item.targetDevice}
        </Text>

        <View style={styles.permissionsRow}>
          {item.permissions?.map((p: string) => (
            <Chip key={p} compact style={styles.permChip} textStyle={{ fontSize: 10 }}>
              {p.replace('_', ' ')}
            </Chip>
          ))}
        </View>

        {item.expiresAt && (
          <Text variant="bodySmall" style={{ color: theme.colors.onSurfaceVariant }}>
            Expires: {new Date(item.expiresAt).toLocaleDateString()}
          </Text>
        )}
      </Card.Content>
      <Card.Actions>
        {item.status === 'pending' && (
          <Button onPress={() => handleAccept(item._id)} mode="contained" compact>
            Accept
          </Button>
        )}
        {(item.status === 'active' || item.status === 'pending') && (
          <Button onPress={() => handleRevoke(item._id)} textColor={theme.colors.error} compact>
            Revoke
          </Button>
        )}
      </Card.Actions>
    </Card>
  );

  return (
    <View style={[styles.container, { backgroundColor: theme.colors.background }]}>
      <Stack.Screen options={{ title: 'Delegations', headerShown: true }} />

      <FlatList
        data={delegations}
        keyExtractor={(item) => item._id}
        renderItem={renderDelegation}
        refreshControl={
          <RefreshControl refreshing={loading} onRefresh={fetchDelegations} />
        }
        contentContainerStyle={styles.list}
        ListEmptyComponent={
          !loading ? (
            <View style={styles.empty}>
              <Text variant="bodyLarge" style={{ color: theme.colors.onSurfaceVariant }}>
                No delegations yet
              </Text>
              <Text variant="bodySmall" style={{ color: theme.colors.onSurfaceVariant, marginTop: 8 }}>
                Share device control with friends
              </Text>
            </View>
          ) : null
        }
      />

      <Button
        mode="contained"
        icon="plus"
        onPress={() => setDialogVisible(true)}
        style={styles.createBtn}
      >
        New Delegation
      </Button>

      <Portal>
        <Dialog visible={dialogVisible} onDismiss={() => setDialogVisible(false)}>
          <Dialog.Title>Create Delegation</Dialog.Title>
          <Dialog.Content>
            <TextInput
              label="Delegate User ID"
              value={delegateId}
              onChangeText={setDelegateId}
              mode="outlined"
              dense
              style={styles.input}
            />
            <TextInput
              label="Target Device ID"
              value={targetDeviceId}
              onChangeText={setTargetDeviceId}
              mode="outlined"
              dense
              style={styles.input}
            />
            <Text variant="bodyMedium" style={{ marginTop: 12, marginBottom: 8 }}>
              Permissions:
            </Text>
            {PERMISSION_OPTIONS.map((opt) => (
              <Checkbox.Item
                key={opt.key}
                label={opt.label}
                status={selectedPermissions.includes(opt.key) ? 'checked' : 'unchecked'}
                onPress={() => togglePermission(opt.key)}
              />
            ))}
          </Dialog.Content>
          <Dialog.Actions>
            <Button onPress={() => setDialogVisible(false)}>Cancel</Button>
            <Button onPress={handleCreate} mode="contained">
              Create
            </Button>
          </Dialog.Actions>
        </Dialog>
      </Portal>
    </View>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1 },
  list: { padding: 16, paddingBottom: 80 },
  card: { marginBottom: 12 },
  headerRow: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center' },
  permissionsRow: { flexDirection: 'row', flexWrap: 'wrap', marginTop: 8, gap: 4 },
  permChip: { marginRight: 4 },
  empty: { alignItems: 'center', marginTop: 60 },
  createBtn: { position: 'absolute', bottom: 16, left: 16, right: 16 },
  input: { marginBottom: 8 },
});
