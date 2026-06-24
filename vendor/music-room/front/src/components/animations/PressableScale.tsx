import React, { useRef, useCallback } from 'react';
import { Animated, Pressable, ViewStyle, StyleSheet } from 'react-native';

interface PressableScaleProps {
  children: React.ReactNode;
  onPress?: () => void;
  onLongPress?: () => void;
  activeScale?: number;
  disabled?: boolean;
  style?: ViewStyle;
}

export const PressableScale: React.FC<PressableScaleProps> = ({
  children,
  onPress,
  onLongPress,
  activeScale = 0.95,
  disabled = false,
  style,
}) => {
  const scale = useRef(new Animated.Value(1)).current;

  const handlePressIn = useCallback(() => {
    Animated.spring(scale, {
      toValue: activeScale,
      useNativeDriver: true,
      speed: 50,
      bounciness: 4,
    }).start();
  }, [scale, activeScale]);

  const handlePressOut = useCallback(() => {
    Animated.spring(scale, {
      toValue: 1,
      useNativeDriver: true,
      speed: 50,
      bounciness: 4,
    }).start();
  }, [scale]);

  return (
    <Pressable
      onPress={onPress}
      onLongPress={onLongPress}
      onPressIn={handlePressIn}
      onPressOut={handlePressOut}
      disabled={disabled}
    >
      <Animated.View
        style={[style, { transform: [{ scale }], opacity: disabled ? 0.5 : 1 }]}
      >
        {children}
      </Animated.View>
    </Pressable>
  );
};

interface AnimatedProgressProps {
  progress: number;
  duration?: number;
  height?: number;
  backgroundColor?: string;
  progressColor?: string;
  style?: ViewStyle;
}

export const AnimatedProgress: React.FC<AnimatedProgressProps> = ({
  progress,
  duration = 500,
  height = 4,
  backgroundColor = '#E0E0E0',
  progressColor = '#6C63FF',
  style,
}) => {
  const animatedWidth = useRef(new Animated.Value(0)).current;

  React.useEffect(() => {
    Animated.timing(animatedWidth, {
      toValue: Math.min(Math.max(progress, 0), 1),
      duration,
      useNativeDriver: false,
    }).start();
  }, [progress, duration, animatedWidth]);

  return (
    <Animated.View
      style={[
        {
          height,
          backgroundColor,
          borderRadius: height / 2,
          overflow: 'hidden',
        },
        style,
      ]}
    >
      <Animated.View
        style={{
          height: '100%',
          backgroundColor: progressColor,
          borderRadius: height / 2,
          width: animatedWidth.interpolate({
            inputRange: [0, 1],
            outputRange: ['0%', '100%'],
          }),
        }}
      />
    </Animated.View>
  );
};
