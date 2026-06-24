import { Platform, AccessibilityProps } from 'react-native';

/**
 * Generate consistent accessibility props for interactive elements
 */
export function getA11yProps(
  label: string,
  hint?: string,
  role?: AccessibilityProps['accessibilityRole'],
): AccessibilityProps {
  return {
    accessible: true,
    accessibilityLabel: label,
    accessibilityHint: hint,
    accessibilityRole: role || 'button',
  };
}

/**
 * Generate accessibility props for images
 */
export function getImageA11yProps(description: string): AccessibilityProps {
  return {
    accessible: true,
    accessibilityLabel: description,
    accessibilityRole: 'image',
  };
}

/**
 * Generate accessibility props for text headings
 */
export function getHeadingA11yProps(text: string): AccessibilityProps {
  return {
    accessible: true,
    accessibilityLabel: text,
    accessibilityRole: 'header',
  };
}

/**
 * Generate accessibility props for links
 */
export function getLinkA11yProps(label: string, hint?: string): AccessibilityProps {
  return {
    accessible: true,
    accessibilityLabel: label,
    accessibilityHint: hint || `Opens ${label}`,
    accessibilityRole: 'link',
  };
}

/**
 * Generate accessibility props for tab bar items
 */
export function getTabA11yProps(
  label: string,
  isSelected: boolean,
  index: number,
  total: number,
): AccessibilityProps {
  return {
    accessible: true,
    accessibilityLabel: `${label} tab, ${index + 1} of ${total}`,
    accessibilityRole: 'tab',
    accessibilityState: { selected: isSelected },
  };
}

/**
 * Announce for screen readers (VoiceOver / TalkBack)
 */
export function announceForAccessibility(message: string): void {
  if (Platform.OS === 'web') return;

  try {
    const { AccessibilityInfo } = require('react-native');
    AccessibilityInfo.announceForAccessibility(message);
  } catch {
    // Silently fail if AccessibilityInfo not available
  }
}

/**
 * Check if a screen reader is currently active
 */
export async function isScreenReaderEnabled(): Promise<boolean> {
  if (Platform.OS === 'web') return false;

  try {
    const { AccessibilityInfo } = require('react-native');
    return AccessibilityInfo.isScreenReaderEnabled();
  } catch {
    return false;
  }
}

/**
 * Minimum touch target size (44x44 per WCAG 2.5.8)
 */
export const MIN_TOUCH_TARGET = 44;

/**
 * Generate style for meeting minimum touch target
 */
export function ensureMinTouchTarget(
  width?: number,
  height?: number,
): { minWidth: number; minHeight: number } {
  return {
    minWidth: Math.max(width || 0, MIN_TOUCH_TARGET),
    minHeight: Math.max(height || 0, MIN_TOUCH_TARGET),
  };
}
