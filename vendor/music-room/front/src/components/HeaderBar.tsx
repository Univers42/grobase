import React from 'react';
import { View, StyleSheet, Image, ViewStyle } from 'react-native';
import { Text, useTheme, IconButton } from 'react-native-paper';

interface HeaderBarProps {
  title: string;
  subtitle?: string;
  leftIcon?: string;
  rightIcon?: string;
  onLeftPress?: () => void;
  onRightPress?: () => void;
  showAvatar?: boolean;
  avatarUri?: string;
  style?: ViewStyle;
}

export const HeaderBar: React.FC<HeaderBarProps> = ({
  title,
  subtitle,
  leftIcon = 'arrow-left',
  rightIcon,
  onLeftPress,
  onRightPress,
  showAvatar = false,
  avatarUri,
  style,
}) => {
  const theme = useTheme();

  return (
    <View
      style={[
        styles.container,
        { backgroundColor: theme.colors.surface },
        style,
      ]}
      accessibilityRole="header"
    >
      <View style={styles.left}>
        {onLeftPress && (
          <IconButton
            icon={leftIcon}
            onPress={onLeftPress}
            accessibilityLabel="Go back"
            size={24}
          />
        )}
        {showAvatar && avatarUri && (
          <Image
            source={{ uri: avatarUri }}
            style={styles.avatar}
            accessibilityLabel="User avatar"
          />
        )}
      </View>

      <View style={styles.center}>
        <Text variant="titleMedium" numberOfLines={1} style={styles.title}>
          {title}
        </Text>
        {subtitle && (
          <Text variant="bodySmall" numberOfLines={1} style={{ color: theme.colors.onSurfaceVariant }}>
            {subtitle}
          </Text>
        )}
      </View>

      <View style={styles.right}>
        {rightIcon && onRightPress && (
          <IconButton icon={rightIcon} onPress={onRightPress} size={24} />
        )}
      </View>
    </View>
  );
};

const styles = StyleSheet.create({
  container: {
    flexDirection: 'row',
    alignItems: 'center',
    paddingHorizontal: 4,
    paddingVertical: 8,
    minHeight: 56,
    elevation: 2,
  },
  left: {
    flexDirection: 'row',
    alignItems: 'center',
    minWidth: 48,
  },
  center: {
    flex: 1,
    alignItems: 'center',
  },
  right: {
    minWidth: 48,
    alignItems: 'flex-end',
  },
  title: {
    fontWeight: '600',
  },
  avatar: {
    width: 32,
    height: 32,
    borderRadius: 16,
    marginLeft: 8,
  },
});
