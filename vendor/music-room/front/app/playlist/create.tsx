import { useState } from 'react';
import { View, StyleSheet, ScrollView, KeyboardAvoidingView, Platform } from 'react-native';
import {
  TextInput,
  Button,
  Text,
  SegmentedButtons,
  HelperText,
  useTheme,
} from 'react-native-paper';
import { useRouter, Stack } from 'expo-router';
import { playlistApi, ApiError } from '../../src/services';
import { useAuthStore } from '../../src/stores';

export default function CreatePlaylistScreen() {
  const theme = useTheme();
  const router = useRouter();
  const token = useAuthStore((s) => s.token);

  const [name, setName] = useState('');
  const [description, setDescription] = useState('');
  const [visibility, setVisibility] = useState('public');
  const [licenseType, setLicenseType] = useState('open');
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState('');

  const handleCreate = async () => {
    if (!name.trim()) {
      setError('Playlist name is required');
      return;
    }
    if (!token) return;

    setError('');
    setLoading(true);
    try {
      const playlist = await playlistApi.create(
        {
          name: name.trim(),
          description: description.trim() || undefined,
          visibility,
          licenseType,
        },
        token,
      );
      router.replace(`/playlist/${playlist._id}`);
    } catch (err) {
      if (err instanceof ApiError) {
        setError(err.message);
      } else {
        setError('Failed to create playlist');
      }
    } finally {
      setLoading(false);
    }
  };

  return (
    <KeyboardAvoidingView
      style={[styles.container, { backgroundColor: theme.colors.background }]}
      behavior={Platform.OS === 'ios' ? 'padding' : 'height'}
    >
      <Stack.Screen options={{ title: 'Create Playlist' }} />
      <ScrollView contentContainerStyle={styles.scroll} keyboardShouldPersistTaps="handled">
        <View style={styles.form}>
          <TextInput
            label="Playlist Name"
            value={name}
            onChangeText={setName}
            mode="outlined"
            left={<TextInput.Icon icon="playlist-music" />}
          />

          <TextInput
            label="Description (optional)"
            value={description}
            onChangeText={setDescription}
            mode="outlined"
            multiline
            numberOfLines={3}
          />

          <View>
            <Text variant="labelLarge" style={{ color: theme.colors.onSurface, marginBottom: 8 }}>
              Visibility
            </Text>
            <SegmentedButtons
              value={visibility}
              onValueChange={setVisibility}
              buttons={[
                { value: 'public', label: 'Public' },
                { value: 'private', label: 'Private' },
              ]}
            />
          </View>

          <View>
            <Text variant="labelLarge" style={{ color: theme.colors.onSurface, marginBottom: 8 }}>
              Collaboration
            </Text>
            <SegmentedButtons
              value={licenseType}
              onValueChange={setLicenseType}
              buttons={[
                { value: 'open', label: 'Open' },
                { value: 'invited_only', label: 'Invite Only' },
              ]}
            />
          </View>

          {error ? (
            <HelperText type="error" visible>
              {error}
            </HelperText>
          ) : null}

          <Button
            mode="contained"
            onPress={handleCreate}
            loading={loading}
            disabled={loading}
            style={styles.button}
            contentStyle={styles.buttonContent}
          >
            Create Playlist
          </Button>
        </View>
      </ScrollView>
    </KeyboardAvoidingView>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1 },
  scroll: { padding: 16 },
  form: { gap: 16 },
  button: { marginTop: 8 },
  buttonContent: { paddingVertical: 6 },
});
