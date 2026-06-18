import { useEffect, useRef, useState, useCallback } from 'react';
import { AppState, AppStateStatus } from 'react-native';

/**
 * Hook to track app foreground/background state
 */
export function useAppState() {
  const [appState, setAppState] = useState<AppStateStatus>(AppState.currentState);
  const previousState = useRef<AppStateStatus>(AppState.currentState);

  useEffect(() => {
    const subscription = AppState.addEventListener('change', (nextState) => {
      previousState.current = appState;
      setAppState(nextState);
    });

    return () => subscription.remove();
  }, [appState]);

  return {
    appState,
    previousState: previousState.current,
    isActive: appState === 'active',
    isBackground: appState === 'background',
    isInactive: appState === 'inactive',
    justBecameActive: previousState.current !== 'active' && appState === 'active',
    justWentToBackground: previousState.current === 'active' && appState !== 'active',
  };
}
