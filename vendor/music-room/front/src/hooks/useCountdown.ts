import { useState, useCallback, useRef, useEffect } from 'react';

interface CountdownOptions {
  initialSeconds: number;
  autoStart?: boolean;
  onComplete?: () => void;
  interval?: number;
}

/**
 * Hook for countdown timer (useful for OTP/verification code resend)
 */
export function useCountdown({
  initialSeconds,
  autoStart = false,
  onComplete,
  interval = 1000,
}: CountdownOptions) {
  const [seconds, setSeconds] = useState(initialSeconds);
  const [isRunning, setIsRunning] = useState(autoStart);
  const intervalRef = useRef<NodeJS.Timeout | null>(null);

  const clear = useCallback(() => {
    if (intervalRef.current) {
      clearInterval(intervalRef.current);
      intervalRef.current = null;
    }
  }, []);

  const start = useCallback(() => {
    clear();
    setIsRunning(true);
  }, [clear]);

  const stop = useCallback(() => {
    clear();
    setIsRunning(false);
  }, [clear]);

  const reset = useCallback(
    (newSeconds?: number) => {
      clear();
      setSeconds(newSeconds ?? initialSeconds);
      setIsRunning(false);
    },
    [clear, initialSeconds],
  );

  const restart = useCallback(
    (newSeconds?: number) => {
      clear();
      setSeconds(newSeconds ?? initialSeconds);
      setIsRunning(true);
    },
    [clear, initialSeconds],
  );

  useEffect(() => {
    if (!isRunning) return;

    intervalRef.current = setInterval(() => {
      setSeconds((prev) => {
        if (prev <= 1) {
          clear();
          setIsRunning(false);
          onComplete?.();
          return 0;
        }
        return prev - 1;
      });
    }, interval);

    return clear;
  }, [isRunning, interval, clear, onComplete]);

  const minutes = Math.floor(seconds / 60);
  const remainingSeconds = seconds % 60;
  const formatted = `${minutes}:${remainingSeconds.toString().padStart(2, '0')}`;

  return {
    seconds,
    minutes,
    remainingSeconds,
    formatted,
    isRunning,
    isComplete: seconds === 0,
    start,
    stop,
    reset,
    restart,
  };
}
