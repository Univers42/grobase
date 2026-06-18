import React from 'react';
import { View, StyleSheet } from 'react-native';
import { Chip, useTheme } from 'react-native-paper';

interface TagListProps {
  tags: string[];
  selectedTags?: string[];
  onToggle?: (tag: string) => void;
  compact?: boolean;
  scrollable?: boolean;
}

export function TagList({ tags, selectedTags = [], onToggle, compact }: TagListProps) {
  const theme = useTheme();

  return (
    <View style={styles.container}>
      {tags.map((tag) => {
        const isSelected = selectedTags.includes(tag);
        return (
          <Chip
            key={tag}
            mode={isSelected ? 'flat' : 'outlined'}
            selected={isSelected}
            onPress={onToggle ? () => onToggle(tag) : undefined}
            compact={compact}
            style={styles.chip}
            textStyle={compact ? { fontSize: 11 } : undefined}
          >
            {tag}
          </Chip>
        );
      })}
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    gap: 6,
  },
  chip: {
    marginBottom: 2,
  },
});
