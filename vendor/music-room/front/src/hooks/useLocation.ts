import { useState, useEffect, useRef } from 'react';
import * as Location from 'expo-location';

interface LocationState {
  latitude: number | null;
  longitude: number | null;
  loading: boolean;
  error: string | null;
  permissionGranted: boolean;
}

/**
 * Hook to get the user's current location
 * Requests permission and watches position updates
 */
export function useLocation(watch = false): LocationState {
  const [state, setState] = useState<LocationState>({
    latitude: null,
    longitude: null,
    loading: true,
    error: null,
    permissionGranted: false,
  });
  const subscriptionRef = useRef<Location.LocationSubscription | null>(null);

  useEffect(() => {
    let mounted = true;

    async function getLocation() {
      try {
        const { status } = await Location.requestForegroundPermissionsAsync();

        if (status !== 'granted') {
          if (mounted) {
            setState((s) => ({
              ...s,
              loading: false,
              error: 'Location permission denied',
              permissionGranted: false,
            }));
          }
          return;
        }

        if (mounted) {
          setState((s) => ({ ...s, permissionGranted: true }));
        }

        const location = await Location.getCurrentPositionAsync({
          accuracy: Location.Accuracy.Balanced,
        });

        if (mounted) {
          setState((s) => ({
            ...s,
            latitude: location.coords.latitude,
            longitude: location.coords.longitude,
            loading: false,
          }));
        }

        if (watch) {
          subscriptionRef.current = await Location.watchPositionAsync(
            {
              accuracy: Location.Accuracy.Balanced,
              distanceInterval: 100,
            },
            (loc) => {
              if (mounted) {
                setState((s) => ({
                  ...s,
                  latitude: loc.coords.latitude,
                  longitude: loc.coords.longitude,
                }));
              }
            },
          );
        }
      } catch (err: any) {
        if (mounted) {
          setState((s) => ({
            ...s,
            loading: false,
            error: err.message || 'Failed to get location',
          }));
        }
      }
    }

    getLocation();

    return () => {
      mounted = false;
      subscriptionRef.current?.remove();
    };
  }, [watch]);

  return state;
}
