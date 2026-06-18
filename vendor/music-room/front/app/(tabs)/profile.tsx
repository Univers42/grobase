import { useState } from 'react';
import { View, StyleSheet, ScrollView } from 'react-native';
import {
  Text,
  Avatar,
  Button,
  Card,
  TextInput,
  Divider,
  List,
  useTheme,
} from 'react-native-paper';
import { useRouter } from 'expo-router';
import { useAuthStore } from '../../src/stores';
import { userApi, ApiError } from '../../src/services';

export default function ProfileScreen() {
  const theme = useTheme();
  const router = useRouter();
  const { user, token, logout, updateUser } = useAuthStore();

  const [editing, setEditing] = useState(false);
  const [displayName, setDisplayName] = useState(user?.publicInfo?.displayName || '');
  const [bio, setBio] = useState(user?.publicInfo?.bio || '');
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState('');

  const handleSave = async () => {
    if (!token) return;
    setSaving(true);
    setError('');
    try {
      await userApi.updatePublicInfo({ displayName: displayName.trim(), bio: bio.trim() }, token);
      updateUser({
        publicInfo: {
          ...user?.publicInfo,
          displayName: displayName.trim(),
          bio: bio.trim(),
        },
      });
      setEditing(false);
    } catch (err) {
      if (err instanceof ApiError) {
        setError(err.message);
      } else {
        setError('Failed to update profile');
      }
    } finally {
      setSaving(false);
    }
  };

  const handleLogout = async () => {
    await logout();
    router.replace('/(auth)/login');
  };

  const initials = (user?.publicInfo?.displayName || user?.email || '?')
    .slice(0, 2)
    .toUpperCase();

  return (
    <ScrollView
      style={[styles.container, { backgroundColor: theme.colors.background }]}
      contentContainerStyle={styles.content}
    >
      {/* Avatar & Name */}
      <View style={styles.avatarSection}>
        {user?.publicInfo?.avatar ? (
          <Avatar.Image size={80} source={{ uri: user.publicInfo.avatar }} />
        ) : (
          <Avatar.Text
            size={80}
            label={initials}
            style={{ backgroundColor: theme.colors.primary }}
          />
        )}
        <Text variant="headlineSmall" style={{ color: theme.colors.onBackground, marginTop: 12 }}>
          {user?.publicInfo?.displayName || 'User'}
        </Text>
        <Text variant="bodyMedium" style={{ color: theme.colors.onSurfaceVariant }}>
          {user?.email}
        </Text>
      </View>

      <Divider style={styles.divider} />

      {/* Edit Profile */}
      <Card style={[styles.card, { backgroundColor: theme.colors.surface }]}>
        <Card.Title title="Profile Info" />
        <Card.Content>
          {editing ? (
            <View style={styles.form}>
              <TextInput
                label="Display Name"
                value={displayName}
                onChangeText={setDisplayName}
                mode="outlined"
              />
              <TextInput
                label="Bio"
                value={bio}
                onChangeText={setBio}
                mode="outlined"
                multiline
                numberOfLines={3}
              />
              {error ? (
                <Text variant="bodySmall" style={{ color: theme.colors.error }}>
                  {error}
                </Text>
              ) : null}
              <View style={styles.editButtons}>
                <Button mode="outlined" onPress={() => setEditing(false)}>
                  Cancel
                </Button>
                <Button mode="contained" onPress={handleSave} loading={saving}>
                  Save
                </Button>
              </View>
            </View>
          ) : (
            <View>
              <List.Item
                title="Display Name"
                description={user?.publicInfo?.displayName || 'Not set'}
              />
              <List.Item
                title="Bio"
                description={user?.publicInfo?.bio || 'No bio yet'}
              />
              <Button
                mode="outlined"
                onPress={() => setEditing(true)}
                style={styles.editButton}
              >
                Edit Profile
              </Button>
            </View>
          )}
        </Card.Content>
      </Card>

      {/* Quick Links */}
      <Card style={[styles.card, { backgroundColor: theme.colors.surface }]}>
        <Card.Content>
          <List.Item
            title="Friends"
            left={(props) => <List.Icon {...props} icon="account-group" />}
            right={(props) => <List.Icon {...props} icon="chevron-right" />}
            onPress={() => router.push('/friends')}
          />
          <List.Item
            title="Music Preferences"
            left={(props) => <List.Icon {...props} icon="music-note" />}
            right={(props) => <List.Icon {...props} icon="chevron-right" />}
            onPress={() => router.push('/preferences')}
          />
          <List.Item
            title="Subscription"
            left={(props) => <List.Icon {...props} icon="crown" />}
            right={(props) => <List.Icon {...props} icon="chevron-right" />}
            onPress={() => router.push('/subscription')}
          />
          <List.Item
            title="Devices"
            left={(props) => <List.Icon {...props} icon="cellphone" />}
            right={(props) => <List.Icon {...props} icon="chevron-right" />}
            onPress={() => router.push('/devices')}
          />
          <List.Item
            title="Delegations"
            description="Share device control"
            left={(props) => <List.Icon {...props} icon="share-variant" />}
            right={(props) => <List.Icon {...props} icon="chevron-right" />}
            onPress={() => router.push('/delegations')}
          />
          <List.Item
            title="Settings"
            left={(props) => <List.Icon {...props} icon="cog" />}
            right={(props) => <List.Icon {...props} icon="chevron-right" />}
            onPress={() => router.push('/settings')}
          />
        </Card.Content>
      </Card>

      {/* Logout */}
      <Button
        mode="outlined"
        onPress={handleLogout}
        textColor={theme.colors.error}
        style={[styles.logoutButton, { borderColor: theme.colors.error }]}
      >
        Sign Out
      </Button>
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
  },
  content: {
    padding: 16,
    paddingBottom: 32,
  },
  avatarSection: {
    alignItems: 'center',
    marginVertical: 16,
  },
  divider: {
    marginVertical: 16,
  },
  card: {
    borderRadius: 12,
    marginBottom: 16,
    elevation: 2,
  },
  form: {
    gap: 12,
  },
  editButtons: {
    flexDirection: 'row',
    justifyContent: 'flex-end',
    gap: 12,
  },
  editButton: {
    marginTop: 8,
    alignSelf: 'flex-start',
  },
  logoutButton: {
    marginTop: 8,
  },
});
