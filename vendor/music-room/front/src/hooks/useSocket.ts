import { useEffect, useRef, useCallback, useState } from 'react';
import { io, Socket } from 'socket.io-client';
import { useAuthStore } from '../stores/authStore';

const API_URL = process.env.EXPO_PUBLIC_API_URL || 'http://localhost:3000';

interface UseSocketOptions {
  namespace: string;
  room?: string;
  enabled?: boolean;
}

interface UseSocketReturn {
  socket: Socket | null;
  isConnected: boolean;
  emit: (event: string, data?: any) => void;
  on: (event: string, handler: (...args: any[]) => void) => void;
  off: (event: string, handler?: (...args: any[]) => void) => void;
}

export function useSocket({
  namespace,
  room,
  enabled = true,
}: UseSocketOptions): UseSocketReturn {
  const socketRef = useRef<Socket | null>(null);
  const [isConnected, setIsConnected] = useState(false);
  const token = useAuthStore((s) => s.token);

  useEffect(() => {
    if (!enabled || !token) return;

    const socket = io(`${API_URL}/${namespace}`, {
      auth: { token },
      transports: ['websocket'],
      reconnection: true,
      reconnectionAttempts: 5,
      reconnectionDelay: 1000,
    });

    socketRef.current = socket;

    socket.on('connect', () => {
      setIsConnected(true);
      if (room) {
        socket.emit('join', { roomId: room });
      }
    });

    socket.on('disconnect', () => {
      setIsConnected(false);
    });

    socket.on('connect_error', (err) => {
      console.warn(`[Socket/${namespace}] Connection error:`, err.message);
    });

    return () => {
      if (room) {
        socket.emit('leave', { roomId: room });
      }
      socket.disconnect();
      socketRef.current = null;
      setIsConnected(false);
    };
  }, [namespace, room, token, enabled]);

  const emit = useCallback(
    (event: string, data?: any) => {
      socketRef.current?.emit(event, data);
    },
    [],
  );

  const on = useCallback(
    (event: string, handler: (...args: any[]) => void) => {
      socketRef.current?.on(event, handler);
    },
    [],
  );

  const off = useCallback(
    (event: string, handler?: (...args: any[]) => void) => {
      if (handler) {
        socketRef.current?.off(event, handler);
      } else {
        socketRef.current?.removeAllListeners(event);
      }
    },
    [],
  );

  return {
    socket: socketRef.current,
    isConnected,
    emit,
    on,
    off,
  };
}
