import { create } from 'zustand';
import { Audio, AVPlaybackStatus } from 'expo-av';

type Track = {
  deezerTrackId: number;
  title: string;
  artist: string;
  albumCover?: string;
  previewUrl: string;
};

type PlayerState = {
  currentTrack: Track | null;
  isPlaying: boolean;
  position: number; // ms
  duration: number; // ms
  sound: Audio.Sound | null;

  // Actions
  play: (track: Track) => Promise<void>;
  pause: () => Promise<void>;
  resume: () => Promise<void>;
  stop: () => Promise<void>;
  seekTo: (position: number) => Promise<void>;
};

export const usePlayerStore = create<PlayerState>((set, get) => ({
  currentTrack: null,
  isPlaying: false,
  position: 0,
  duration: 0,
  sound: null,

  play: async (track: Track) => {
    const { sound: currentSound } = get();

    // Unload previous sound
    if (currentSound) {
      await currentSound.unloadAsync();
    }

    try {
      await Audio.setAudioModeAsync({
        playsInSilentModeIOS: true,
        staysActiveInBackground: true,
      });

      const { sound } = await Audio.Sound.createAsync(
        { uri: track.previewUrl },
        { shouldPlay: true },
        (status: AVPlaybackStatus) => {
          if (status.isLoaded) {
            set({
              position: status.positionMillis,
              duration: status.durationMillis || 0,
              isPlaying: status.isPlaying,
            });

            // Track finished
            if (status.didJustFinish) {
              set({ isPlaying: false, position: 0 });
            }
          }
        },
      );

      set({ currentTrack: track, sound, isPlaying: true });
    } catch (error) {
      console.error('Failed to play track:', error);
    }
  },

  pause: async () => {
    const { sound } = get();
    if (sound) {
      await sound.pauseAsync();
      set({ isPlaying: false });
    }
  },

  resume: async () => {
    const { sound } = get();
    if (sound) {
      await sound.playAsync();
      set({ isPlaying: true });
    }
  },

  stop: async () => {
    const { sound } = get();
    if (sound) {
      await sound.stopAsync();
      await sound.unloadAsync();
    }
    set({ currentTrack: null, sound: null, isPlaying: false, position: 0, duration: 0 });
  },

  seekTo: async (position: number) => {
    const { sound } = get();
    if (sound) {
      await sound.setPositionAsync(position);
    }
  },
}));
