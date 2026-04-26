import type { ClientSession } from './session.js';

const DEFAULT_STORAGE_KEY = 'mini-baas.auth.session';

export interface SessionStorageAdapter {
  load(): ClientSession | undefined;
  save(session: ClientSession): void;
  clear(): void;
}

export function createMemoryStorageAdapter(): SessionStorageAdapter {
  let current: ClientSession | undefined;

  return {
    load: () => current,
    save: (session) => {
      current = session;
    },
    clear: () => {
      current = undefined;
    },
  };
}

export function createBrowserStorageAdapter(
  key = DEFAULT_STORAGE_KEY,
): SessionStorageAdapter | undefined {
  const localStorageRef = getLocalStorage();
  if (!localStorageRef) return undefined;

  return {
    load: () => {
      const value = localStorageRef.getItem(key);
      if (!value) return undefined;
      try {
        return JSON.parse(value) as ClientSession;
      } catch {
        localStorageRef.removeItem(key);
        return undefined;
      }
    },
    save: (session) => {
      localStorageRef.setItem(key, JSON.stringify(session));
    },
    clear: () => {
      localStorageRef.removeItem(key);
    },
  };
}

function getLocalStorage(): Storage | undefined {
  try {
    if (typeof globalThis === 'undefined') return undefined;
    return globalThis.localStorage;
  } catch {
    return undefined;
  }
}
