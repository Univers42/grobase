import { useState, useEffect } from 'react';
import { View, StyleSheet, ScrollView } from 'react-native';
import { Text, Card, Button, Chip, useTheme, ActivityIndicator } from 'react-native-paper';
import { Stack } from 'expo-router';
import { api } from '../src/services';
import { useAuthStore } from '../src/stores';

type SubscriptionData = {
  plan: string;
  status: string;
  features: {
    maxPlaylists: number;
    maxEventsPerMonth: number;
    maxCollaboratorsPerPlaylist: number;
    canExportPlaylist: boolean;
    adsEnabled: boolean;
    prioritySupport: boolean;
  };
  currentPeriodEnd?: string;
};

export default function SubscriptionScreen() {
  const theme = useTheme();
  const token = useAuthStore((s) => s.token);

  const [sub, setSub] = useState<SubscriptionData | null>(null);
  const [loading, setLoading] = useState(true);
  const [upgrading, setUpgrading] = useState(false);

  useEffect(() => {
    if (!token) return;
    api.get('/subscriptions/me', token)
      .then(setSub)
      .catch(console.error)
      .finally(() => setLoading(false));
  }, [token]);

  const handleUpgrade = async () => {
    if (!token) return;
    setUpgrading(true);
    try {
      const result = await api.post('/subscriptions/upgrade', { plan: 'premium' }, token);
      setSub(result);
    } catch (err) {
      console.error('Upgrade failed:', err);
    } finally {
      setUpgrading(false);
    }
  };

  if (loading) {
    return (
      <View style={[styles.center, { backgroundColor: theme.colors.background }]}>
        <ActivityIndicator size="large" />
      </View>
    );
  }

  const isPremium = sub?.plan === 'premium';
  const formatLimit = (v: number) => (v === -1 ? 'Unlimited' : v.toString());

  return (
    <ScrollView
      style={[styles.container, { backgroundColor: theme.colors.background }]}
      contentContainerStyle={styles.content}
    >
      <Stack.Screen options={{ title: 'Subscription' }} />

      <Card style={[styles.card, { backgroundColor: theme.colors.surface }]}>
        <Card.Content style={styles.planHeader}>
          <Text variant="headlineMedium" style={{ color: theme.colors.primary, fontWeight: '700' }}>
            {isPremium ? '👑 Premium' : '🎵 Free'}
          </Text>
          <Chip
            style={{
              backgroundColor: sub?.status === 'active'
                ? theme.colors.primaryContainer
                : theme.colors.errorContainer,
            }}
          >
            {sub?.status || 'unknown'}
          </Chip>
        </Card.Content>
      </Card>

      <Card style={[styles.card, { backgroundColor: theme.colors.surface }]}>
        <Card.Title title="Features" />
        <Card.Content style={styles.features}>
          <FeatureRow label="Playlists" value={formatLimit(sub?.features.maxPlaylists || 5)} />
          <FeatureRow label="Events/month" value={formatLimit(sub?.features.maxEventsPerMonth || 3)} />
          <FeatureRow label="Collaborators" value={formatLimit(sub?.features.maxCollaboratorsPerPlaylist || 5)} />
          <FeatureRow label="Export playlists" value={sub?.features.canExportPlaylist ? '✅' : '❌'} />
          <FeatureRow label="Ads" value={sub?.features.adsEnabled ? 'Yes' : 'None'} />
          <FeatureRow label="Priority support" value={sub?.features.prioritySupport ? '✅' : '❌'} />
        </Card.Content>
      </Card>

      {!isPremium ? (
        <Button
          mode="contained"
          onPress={handleUpgrade}
          loading={upgrading}
          style={styles.upgradeButton}
          contentStyle={styles.buttonContent}
        >
          Upgrade to Premium
        </Button>
      ) : (
        <Text variant="bodyMedium" style={{ color: theme.colors.onSurfaceVariant, textAlign: 'center', marginTop: 16 }}>
          {sub?.currentPeriodEnd
            ? `Renews: ${new Date(sub.currentPeriodEnd).toLocaleDateString()}`
            : 'Active subscription'}
        </Text>
      )}
    </ScrollView>
  );
}

function FeatureRow({ label, value }: { label: string; value: string }) {
  const theme = useTheme();
  return (
    <View style={styles.featureRow}>
      <Text variant="bodyMedium" style={{ color: theme.colors.onSurface }}>{label}</Text>
      <Text variant="bodyMedium" style={{ color: theme.colors.primary, fontWeight: '600' }}>{value}</Text>
    </View>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1 },
  content: { padding: 16, paddingBottom: 32 },
  center: { flex: 1, justifyContent: 'center', alignItems: 'center' },
  card: { borderRadius: 12, marginBottom: 16, elevation: 2 },
  planHeader: { alignItems: 'center', gap: 8, paddingVertical: 16 },
  features: { gap: 8 },
  featureRow: { flexDirection: 'row', justifyContent: 'space-between', paddingVertical: 4 },
  upgradeButton: { marginTop: 16 },
  buttonContent: { paddingVertical: 8 },
});
