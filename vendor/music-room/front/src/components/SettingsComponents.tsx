import React, { useState } from 'react';
import { View, StyleSheet } from 'react-native';
import { Text, Switch, List, Divider, useTheme } from 'react-native-paper';

interface SettingsToggleProps {
  label: string;
  description?: string;
  value: boolean;
  onToggle: (value: boolean) => void;
  icon?: string;
  disabled?: boolean;
}

export function SettingsToggle({
  label,
  description,
  value,
  onToggle,
  icon,
  disabled = false,
}: SettingsToggleProps) {
  const theme = useTheme();

  return (
    <List.Item
      title={label}
      description={description}
      left={icon ? (props) => <List.Icon {...props} icon={icon} /> : undefined}
      right={() => (
        <Switch
          value={value}
          onValueChange={onToggle}
          disabled={disabled}
          color={theme.colors.primary}
        />
      )}
      disabled={disabled}
      style={styles.item}
    />
  );
}

interface SettingsSectionProps {
  title: string;
  children: React.ReactNode;
}

export function SettingsSection({ title, children }: SettingsSectionProps) {
  return (
    <View style={styles.section}>
      <Text variant="titleSmall" style={styles.sectionTitle}>
        {title.toUpperCase()}
      </Text>
      <View style={styles.sectionContent}>{children}</View>
    </View>
  );
}

const styles = StyleSheet.create({
  item: {
    paddingVertical: 4,
  },
  section: {
    marginBottom: 24,
  },
  sectionTitle: {
    paddingHorizontal: 16,
    paddingVertical: 8,
    opacity: 0.6,
    fontWeight: '600',
    letterSpacing: 1,
    fontSize: 11,
  },
  sectionContent: {
    backgroundColor: 'rgba(0,0,0,0.02)',
    borderRadius: 12,
    marginHorizontal: 16,
    overflow: 'hidden',
  },
});
