import React from 'react';
import { View, StyleSheet } from 'react-native';
import { Searchbar, useTheme } from 'react-native-paper';

interface SearchHeaderProps {
  value: string;
  onChangeText: (text: string) => void;
  placeholder?: string;
  onSubmit?: () => void;
  loading?: boolean;
  autoFocus?: boolean;
}

export function SearchHeader({
  value,
  onChangeText,
  placeholder = 'Search...',
  onSubmit,
  loading,
  autoFocus,
}: SearchHeaderProps) {
  const theme = useTheme();

  return (
    <View style={[styles.container, { backgroundColor: theme.colors.surface }]}>
      <Searchbar
        placeholder={placeholder}
        value={value}
        onChangeText={onChangeText}
        onSubmitEditing={onSubmit}
        loading={loading}
        autoFocus={autoFocus}
        style={styles.searchbar}
        elevation={0}
      />
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    paddingHorizontal: 16,
    paddingVertical: 8,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: 'rgba(0,0,0,0.1)',
  },
  searchbar: {
    borderRadius: 12,
  },
});
