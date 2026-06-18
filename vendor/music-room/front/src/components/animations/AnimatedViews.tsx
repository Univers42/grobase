import React, { useCallback, useRef } from 'react';
import { Animated, StyleSheet, ViewStyle } from 'react-native';

interface FadeInViewProps {
  children: React.ReactNode;
  duration?: number;
  delay?: number;
  style?: ViewStyle;
}

export const FadeInView: React.FC<FadeInViewProps> = ({
  children,
  duration = 300,
  delay = 0,
  style,
}) => {
  const opacity = useRef(new Animated.Value(0)).current;

  React.useEffect(() => {
    Animated.timing(opacity, {
      toValue: 1,
      duration,
      delay,
      useNativeDriver: true,
    }).start();
  }, [opacity, duration, delay]);

  return (
    <Animated.View style={[style, { opacity }]}>
      {children}
    </Animated.View>
  );
};

interface SlideInViewProps {
  children: React.ReactNode;
  direction?: 'left' | 'right' | 'up' | 'down';
  distance?: number;
  duration?: number;
  delay?: number;
  style?: ViewStyle;
}

export const SlideInView: React.FC<SlideInViewProps> = ({
  children,
  direction = 'up',
  distance = 50,
  duration = 400,
  delay = 0,
  style,
}) => {
  const translateValue = useRef(new Animated.Value(distance)).current;
  const opacity = useRef(new Animated.Value(0)).current;

  const getTransform = () => {
    switch (direction) {
      case 'left':
        return { translateX: translateValue };
      case 'right':
        return { translateX: Animated.multiply(translateValue, -1) };
      case 'down':
        return { translateY: Animated.multiply(translateValue, -1) };
      case 'up':
      default:
        return { translateY: translateValue };
    }
  };

  React.useEffect(() => {
    Animated.parallel([
      Animated.timing(translateValue, {
        toValue: 0,
        duration,
        delay,
        useNativeDriver: true,
      }),
      Animated.timing(opacity, {
        toValue: 1,
        duration: duration * 0.6,
        delay,
        useNativeDriver: true,
      }),
    ]).start();
  }, [translateValue, opacity, duration, delay]);

  return (
    <Animated.View
      style={[style, { opacity, transform: [getTransform()] }]}
    >
      {children}
    </Animated.View>
  );
};

interface ScaleInViewProps {
  children: React.ReactNode;
  duration?: number;
  delay?: number;
  initialScale?: number;
  style?: ViewStyle;
}

export const ScaleInView: React.FC<ScaleInViewProps> = ({
  children,
  duration = 300,
  delay = 0,
  initialScale = 0.8,
  style,
}) => {
  const scale = useRef(new Animated.Value(initialScale)).current;
  const opacity = useRef(new Animated.Value(0)).current;

  React.useEffect(() => {
    Animated.parallel([
      Animated.spring(scale, {
        toValue: 1,
        delay,
        useNativeDriver: true,
        tension: 50,
        friction: 7,
      }),
      Animated.timing(opacity, {
        toValue: 1,
        duration: duration * 0.5,
        delay,
        useNativeDriver: true,
      }),
    ]).start();
  }, [scale, opacity, duration, delay]);

  return (
    <Animated.View
      style={[style, { opacity, transform: [{ scale }] }]}
    >
      {children}
    </Animated.View>
  );
};
