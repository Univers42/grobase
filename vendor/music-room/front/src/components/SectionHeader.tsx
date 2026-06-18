import React from 'react';
import { View, StyleSheet, ViewStyle } from 'react-native';
import { Divider, Text, useTheme } from 'react-native-paper';

interface SectionHeaderProps {
  title: string;
  subtitle?: string;
  action?: React.ReactNode;
  showDivider?: boolean;
  style?: ViewStyle;
}

export const SectionHeader: React.FC<SectionHeaderProps> = ({
  title,
  subtitle,
  action,
  showDivider = true,
  style,
}) => {
  const theme = useTheme();

  return (
    <>
      {showDivider && <Divider style={styles.divider} />}
      <View style={[styles.container, style]}>
        <View style={styles.textContainer}>
          <Text
            variant="titleSmall"
            style={[styles.title, { color: theme.colors.onSurface }]}
            accessibilityRole="header"
          >
            {title}
          </Text>
          {subtitle && (
            <Text
              variant="bodySmall"
              style={{ color: theme.colors.onSurfaceVariant }}
            >
              {subtitle}
            </Text>
          )}
        </View>
        {action && <View style={styles.action}>{action}</View>}
      </View>
    </>
  );
};

const styles = StyleSheet.create({
  container: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    paddingHorizontal: 16,
    paddingVertical: 12,
  },
  textContainer: {
    flex: 1,
  },
  title: {
    fontWeight: '600',
    textTransform: 'uppercase',
    letterSpacing: 0.5,
    fontSize: 12,
  },
  action: {
    marginLeft: 8,
  },
  divider: {
    marginHorizontal: 16,
  },
});
