/**
 * RoleViewContext - Manages the current role view state
 * Allows switching between dev/admin/employee views without routing
 */

import { createContext, useContext, useState, useCallback, useMemo, type ReactNode } from 'react';
import type { RoleView } from '../DevBoard/constants';

interface RoleViewContextValue {
  currentView: RoleView;
  setView: (view: RoleView) => void;
}

const RoleViewContext = createContext<RoleViewContextValue | null>(null);

interface RoleViewProviderProps {
  children: ReactNode;
  defaultView?: RoleView;
}

export function RoleViewProvider({ children, defaultView = 'dev' }: Readonly<RoleViewProviderProps>) {
  const [currentView, setCurrentView] = useState<RoleView>(defaultView);

  const setView = useCallback((view: RoleView) => {
    setCurrentView(view);
  }, []);

  const value = useMemo(() => ({ currentView, setView }), [currentView, setView]);

  return <RoleViewContext.Provider value={value}>{children}</RoleViewContext.Provider>;
}

// eslint-disable-next-line react-refresh/only-export-components
export function useRoleView() {
  const context = useContext(RoleViewContext);
  if (!context) {
    throw new Error('useRoleView must be used within RoleViewProvider');
  }
  return context;
}
