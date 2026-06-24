import { useCallback, useRef } from 'react';
import { Keyboard, Platform } from 'react-native';

/**
 * Hook to manage keyboard behavior
 * Provides dismiss function and ref for input chaining
 */
export function useKeyboard() {
  const inputRefs = useRef<Map<string, any>>(new Map());

  const dismiss = useCallback(() => {
    if (Platform.OS !== 'web') {
      Keyboard.dismiss();
    }
  }, []);

  const registerRef = useCallback((name: string, ref: any) => {
    inputRefs.current.set(name, ref);
  }, []);

  const focusNext = useCallback((name: string) => {
    const ref = inputRefs.current.get(name);
    if (ref?.focus) {
      ref.focus();
    }
  }, []);

  return {
    dismiss,
    registerRef,
    focusNext,
  };
}
