import React from 'react';
import { View, StyleSheet, Dimensions } from 'react-native';
import { Text, useTheme } from 'react-native-paper';

const { width: SCREEN_WIDTH } = Dimensions.get('window');

interface GenreGridItem {
  id: string;
  name: string;
  color: string;
  icon?: string;
}

interface GenreGridProps {
  genres: GenreGridItem[];
  onSelect: (genre: GenreGridItem) => void;
  columns?: number;
}

const GENRE_PRESETS: GenreGridItem[] = [
  { id: 'pop', name: 'Pop', color: '#E91E63' },
  { id: 'rock', name: 'Rock', color: '#9C27B0' },
  { id: 'hiphop', name: 'Hip Hop', color: '#673AB7' },
  { id: 'electronic', name: 'Electronic', color: '#3F51B5' },
  { id: 'jazz', name: 'Jazz', color: '#2196F3' },
  { id: 'classical', name: 'Classical', color: '#009688' },
  { id: 'rnb', name: 'R&B', color: '#4CAF50' },
  { id: 'country', name: 'Country', color: '#FF9800' },
  { id: 'metal', name: 'Metal', color: '#607D8B' },
  { id: 'reggae', name: 'Reggae', color: '#FF5722' },
  { id: 'latin', name: 'Latin', color: '#795548' },
  { id: 'indie', name: 'Indie', color: '#00BCD4' },
];

export function GenreGrid({
  genres = GENRE_PRESETS,
  onSelect,
  columns = 3,
}: GenreGridProps) {
  const theme = useTheme();
  const itemWidth = (SCREEN_WIDTH - 48 - (columns - 1) * 12) / columns;

  return (
    <View style={styles.grid}>
      {genres.map((genre) => (
        <View
          key={genre.id}
          style={[
            styles.genreItem,
            {
              width: itemWidth,
              backgroundColor: genre.color,
            },
          ]}
          onTouchStart={() => onSelect(genre)}
        >
          <Text variant="titleSmall" style={styles.genreText}>
            {genre.name}
          </Text>
        </View>
      ))}
    </View>
  );
}

export { GENRE_PRESETS };

const styles = StyleSheet.create({
  grid: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    paddingHorizontal: 16,
    gap: 12,
  },
  genreItem: {
    height: 80,
    borderRadius: 12,
    justifyContent: 'center',
    alignItems: 'center',
    overflow: 'hidden',
  },
  genreText: {
    color: '#fff',
    fontWeight: '600',
    textShadowColor: 'rgba(0,0,0,0.3)',
    textShadowOffset: { width: 0, height: 1 },
    textShadowRadius: 2,
  },
});
