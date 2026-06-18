import { useState, useEffect } from 'react';
import { View, StyleSheet, ScrollView } from 'react-native';
import { Text, Chip, Button, HelperText, useTheme } from 'react-native-paper';
import { Stack } from 'expo-router';
import { userApi, ApiError } from '../src/services';
import { useAuthStore } from '../src/stores';

const GENRES = [
  'Pop', 'Rock', 'Hip-Hop', 'R&B', 'Electronic', 'Jazz',
  'Classical', 'Country', 'Latin', 'Metal', 'Reggae', 'Blues',
  'Folk', 'Soul', 'Funk', 'Indie', 'Alternative', 'Punk',
];

const MOODS = [
  'Happy', 'Chill', 'Energetic', 'Melancholic', 'Romantic',
  'Focus', 'Party', 'Workout', 'Sleep', 'Road Trip',
];

export default function PreferencesScreen() {
  const theme = useTheme();
  const token = useAuthStore((s) => s.token);
  const user = useAuthStore((s) => s.user);

  const [selectedGenres, setSelectedGenres] = useState<string[]>(
    user?.musicPreferences?.favoriteGenres || [],
  );
  const [selectedMoods, setSelectedMoods] = useState<string[]>(
    user?.musicPreferences?.preferredMoods || [],
  );
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState('');
  const [saved, setSaved] = useState(false);

  const toggleGenre = (genre: string) => {
    setSelectedGenres((prev) =>
      prev.includes(genre) ? prev.filter((g) => g !== genre) : [...prev, genre],
    );
    setSaved(false);
  };

  const toggleMood = (mood: string) => {
    setSelectedMoods((prev) =>
      prev.includes(mood) ? prev.filter((m) => m !== mood) : [...prev, mood],
    );
    setSaved(false);
  };

  const handleSave = async () => {
    if (!token) return;
    setSaving(true);
    setError('');
    try {
      await userApi.updateMusicPreferences(
        { favoriteGenres: selectedGenres, preferredMoods: selectedMoods },
        token,
      );
      setSaved(true);
    } catch (err) {
      if (err instanceof ApiError) setError(err.message);
      else setError('Failed to save');
    } finally {
      setSaving(false);
    }
  };

  return (
    <ScrollView
      style={[styles.container, { backgroundColor: theme.colors.background }]}
      contentContainerStyle={styles.content}
    >
      <Stack.Screen options={{ title: 'Music Preferences' }} />

      <Text variant="titleMedium" style={[styles.section, { color: theme.colors.onBackground }]}>
        Favorite Genres
      </Text>
      <View style={styles.chipGrid}>
        {GENRES.map((genre) => (
          <Chip
            key={genre}
            selected={selectedGenres.includes(genre)}
            onPress={() => toggleGenre(genre)}
            showSelectedOverlay
            style={styles.chip}
          >
            {genre}
          </Chip>
        ))}
      </View>

      <Text variant="titleMedium" style={[styles.section, { color: theme.colors.onBackground }]}>
        Preferred Moods
      </Text>
      <View style={styles.chipGrid}>
        {MOODS.map((mood) => (
          <Chip
            key={mood}
            selected={selectedMoods.includes(mood)}
            onPress={() => toggleMood(mood)}
            showSelectedOverlay
            style={styles.chip}
          >
            {mood}
          </Chip>
        ))}
      </View>

      {error ? (
        <HelperText type="error" visible>{error}</HelperText>
      ) : null}

      {saved ? (
        <Text variant="bodyMedium" style={{ color: theme.colors.primary, textAlign: 'center', marginTop: 8 }}>
          ✅ Preferences saved!
        </Text>
      ) : null}

      <Button
        mode="contained"
        onPress={handleSave}
        loading={saving}
        disabled={saving}
        style={styles.button}
      >
        Save Preferences
      </Button>
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1 },
  content: { padding: 16, paddingBottom: 32 },
  section: { fontWeight: '600', marginTop: 16, marginBottom: 8 },
  chipGrid: { flexDirection: 'row', flexWrap: 'wrap', gap: 8 },
  chip: { marginBottom: 4 },
  button: { marginTop: 24 },
});
