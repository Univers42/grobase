import { Dimensions, PixelRatio, Platform, ScaledSize } from 'react-native';

const { width: SCREEN_WIDTH, height: SCREEN_HEIGHT } = Dimensions.get('window');

// Base dimensions (iPhone 14 Pro)
const BASE_WIDTH = 393;
const BASE_HEIGHT = 852;

/**
 * Scale a value based on screen width
 */
export function scale(size: number): number {
  return PixelRatio.roundToNearestPixel((SCREEN_WIDTH / BASE_WIDTH) * size);
}

/**
 * Scale a value based on screen height
 */
export function verticalScale(size: number): number {
  return PixelRatio.roundToNearestPixel((SCREEN_HEIGHT / BASE_HEIGHT) * size);
}

/**
 * Moderate scale with a damping factor (default 0.5)
 */
export function moderateScale(size: number, factor = 0.5): number {
  return PixelRatio.roundToNearestPixel(size + (scale(size) - size) * factor);
}

/**
 * Get responsive font size
 */
export function fontSize(size: number): number {
  const newSize = scale(size);
  if (Platform.OS === 'ios') {
    return Math.round(PixelRatio.roundToNearestPixel(newSize));
  }
  return Math.round(PixelRatio.roundToNearestPixel(newSize)) - 2;
}

/**
 * Check if device is a tablet
 */
export function isTablet(): boolean {
  const pixelDensity = PixelRatio.get();
  const adjustedWidth = SCREEN_WIDTH * pixelDensity;
  const adjustedHeight = SCREEN_HEIGHT * pixelDensity;
  const diagonalSq = adjustedWidth ** 2 + adjustedHeight ** 2;
  const diagonal = Math.sqrt(diagonalSq) / (pixelDensity * 160);
  return diagonal >= 7;
}

/**
 * Breakpoints for responsive layouts
 */
export const breakpoints = {
  small: 320,
  medium: 375,
  large: 414,
  tablet: 768,
  desktop: 1024,
} as const;

/**
 * Get current breakpoint
 */
export function getCurrentBreakpoint(): keyof typeof breakpoints {
  if (SCREEN_WIDTH >= breakpoints.desktop) return 'desktop';
  if (SCREEN_WIDTH >= breakpoints.tablet) return 'tablet';
  if (SCREEN_WIDTH >= breakpoints.large) return 'large';
  if (SCREEN_WIDTH >= breakpoints.medium) return 'medium';
  return 'small';
}

/**
 * Responsive value based on screen size
 */
export function responsive<T>(values: {
  small?: T;
  medium?: T;
  large?: T;
  tablet?: T;
  desktop?: T;
  default: T;
}): T {
  const bp = getCurrentBreakpoint();
  return values[bp] ?? values.default;
}

export { SCREEN_WIDTH, SCREEN_HEIGHT };
