import { View, StyleSheet, ScrollView } from 'react-native';
import { List, Switch, Text, Divider, useTheme } from 'react-native-paper';
import { Stack } from 'expo-router';
import { useState } from 'react';

export default function SettingsScreen() {
  const theme = useTheme();

  const [notifications, setNotifications] = useState(true);
  const [darkMode, setDarkMode] = useState(false);
  const [autoPlay, setAutoPlay] = useState(true);
  const [highQuality, setHighQuality] = useState(false);
  const [offlineMode, setOfflineMode] = useState(false);

  return (
    <ScrollView style={[styles.container, { backgroundColor: theme.colors.background }]}>
      <Stack.Screen options={{ title: 'Settings', headerShown: true }} />

      <List.Section>
        <List.Subheader>General</List.Subheader>
        <List.Item
          title="Push Notifications"
          description="Receive event and friend notifications"
          left={(props) => <List.Icon {...props} icon="bell" />}
          right={() => (
            <Switch value={notifications} onValueChange={setNotifications} />
          )}
        />
        <Divider />
        <List.Item
          title="Dark Mode"
          description="Use dark theme (follows system by default)"
          left={(props) => <List.Icon {...props} icon="theme-light-dark" />}
          right={() => (
            <Switch value={darkMode} onValueChange={setDarkMode} />
          )}
        />
      </List.Section>

      <List.Section>
        <List.Subheader>Playback</List.Subheader>
        <List.Item
          title="Auto-play Previews"
          description="Automatically play track previews"
          left={(props) => <List.Icon {...props} icon="play-circle" />}
          right={() => (
            <Switch value={autoPlay} onValueChange={setAutoPlay} />
          )}
        />
        <Divider />
        <List.Item
          title="High Quality Audio"
          description="Use higher bitrate for streaming"
          left={(props) => <List.Icon {...props} icon="quality-high" />}
          right={() => (
            <Switch value={highQuality} onValueChange={setHighQuality} />
          )}
        />
      </List.Section>

      <List.Section>
        <List.Subheader>Data</List.Subheader>
        <List.Item
          title="Offline Mode"
          description="Cache tracks for offline playback"
          left={(props) => <List.Icon {...props} icon="download" />}
          right={() => (
            <Switch value={offlineMode} onValueChange={setOfflineMode} />
          )}
        />
      </List.Section>

      <List.Section>
        <List.Subheader>About</List.Subheader>
        <List.Item
          title="Version"
          description="1.0.0"
          left={(props) => <List.Icon {...props} icon="information" />}
        />
        <Divider />
        <List.Item
          title="Privacy Policy"
          left={(props) => <List.Icon {...props} icon="shield-lock" />}
        />
        <Divider />
        <List.Item
          title="Terms of Service"
          left={(props) => <List.Icon {...props} icon="file-document" />}
        />
      </List.Section>
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1 },
});
