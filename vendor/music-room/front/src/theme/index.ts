import { MD3DarkTheme, MD3LightTheme } from 'react-native-paper';

const brandColors = {
  primary: '#6C63FF',
  primaryLight: '#9D97FF',
  primaryDark: '#3F37C9',
  secondary: '#FF6584',
  secondaryLight: '#FF97AC',
  secondaryDark: '#CC4F6A',
  accent: '#00D2FF',
  success: '#4CAF50',
  warning: '#FF9800',
  error: '#F44336',
};

export const lightTheme = {
  ...MD3LightTheme,
  colors: {
    ...MD3LightTheme.colors,
    primary: brandColors.primary,
    primaryContainer: brandColors.primaryLight,
    secondary: brandColors.secondary,
    secondaryContainer: brandColors.secondaryLight,
    tertiary: brandColors.accent,
    error: brandColors.error,
    background: '#F8F9FA',
    surface: '#FFFFFF',
    surfaceVariant: '#F0F0F5',
    onBackground: '#1A1A2E',
    onSurface: '#1A1A2E',
  },
  roundness: 12,
};

export const darkTheme = {
  ...MD3DarkTheme,
  colors: {
    ...MD3DarkTheme.colors,
    primary: brandColors.primary,
    primaryContainer: brandColors.primaryDark,
    secondary: brandColors.secondary,
    secondaryContainer: brandColors.secondaryDark,
    tertiary: brandColors.accent,
    error: brandColors.error,
    background: '#0F0F23',
    surface: '#1A1A2E',
    surfaceVariant: '#252542',
    onBackground: '#E8E8F0',
    onSurface: '#E8E8F0',
  },
  roundness: 12,
};

export const spacing = {
  xs: 4,
  sm: 8,
  md: 16,
  lg: 24,
  xl: 32,
  xxl: 48,
};
