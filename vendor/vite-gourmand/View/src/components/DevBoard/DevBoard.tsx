/**
 * DevBoard - Unified Dashboard component
 * Single page with role-based content switching (SPA pattern)
 */

import { useState, useEffect, useMemo } from 'react';
import { useDevBoard } from './useDevBoard';
import { DevBoardHeader } from './DevBoardHeader';
import { DevBoardSidebar } from './DevBoardSidebar';
import { DevBoardContent } from './DevBoardContent';
import { GradientBackground } from './GradientBackground';
import { SettingsModal } from '../features/qa/settings';
import { ShellFab, ShellModal } from '../cloud-terminal';
import { getCategoriesForRole, getDefaultCategory } from './constants';
import { useMockData } from './useMockData';
import { TestCountProvider } from './TestCountContext';
import { RoleViewProvider, useRoleView } from './RoleViewContext';
import { getDefaultViewForRole } from '../layout/Sidebar';
import { usePortalAuth } from '../../portal_dashboard';
import { useTestRunner } from './useTestRunner';
import type { NavSection } from '../layout/Header/Header';
import './DevBoard.css';

export function DevBoard() {
  const { user } = usePortalAuth();
  // Set default view based on user role
  const defaultView = user?.role ? getDefaultViewForRole(user.role) : 'employee';

  return (
    <RoleViewProvider defaultView={defaultView}>
      <DevBoardInner />
    </RoleViewProvider>
  );
}

function DevBoardInner() {
  const { currentView } = useRoleView();
  const [activeSection, setActiveSection] = useState<NavSection>('dashboard');
  const [isShellOpen, setIsShellOpen] = useState(false);
  const testRunner = useTestRunner();
  const {
    activeCategory,
    isSidebarCollapsed,
    isSettingsOpen,
    selectCategory,
    toggleSidebar,
    closeSettings,
  } = useDevBoard();

  // Reset category when view changes
  useEffect(() => {
    selectCategory(getDefaultCategory(currentView));
  }, [currentView, selectCategory]);

  // Get categories for current role view
  const baseCategories = useMemo(() => getCategoriesForRole(currentView), [currentView]);

  // Get scenario count dynamically from mock data (or real data if available)
  const scenarioCount = useMockData('scenarios').tests.length;

  // Add dynamic test count for dev view
  const categories = useMemo(() => {
    if (currentView !== 'dev') return baseCategories;
    return baseCategories.map((cat) => {
      if (cat.id === 'test-automatics') {
        return { ...cat, count: testRunner.metrics.total };
      }
      if (cat.id === 'scenarios') {
        return { ...cat, count: scenarioCount };
      }
      return cat;
    });
  }, [baseCategories, currentView, testRunner.metrics.total, scenarioCount]);

  // Keyboard shortcut: Ctrl+` to open terminal (desktop only, dev view only)
  useEffect(() => {
    const handleKeyDown = (e: KeyboardEvent) => {
      if (e.ctrlKey && e.key === '`' && globalThis.innerWidth > 768 && currentView === 'dev') {
        e.preventDefault();
        setIsShellOpen((prev) => !prev);
      }
    };
    globalThis.addEventListener('keydown', handleKeyDown);
    return () => globalThis.removeEventListener('keydown', handleKeyDown);
  }, [currentView]);

  return (
    <TestCountProvider value={{ testCount: testRunner.metrics.total }}>
      <div className="devboard">
        <GradientBackground />
        <DevBoardHeader
          activeSection={activeSection}
          onSectionChange={setActiveSection}
          categories={categories}
          activeCategory={activeCategory}
          onCategoryChange={selectCategory}
        />
        <section className="devboard-body">
          <DevBoardSidebar
            categories={categories}
            activeCategory={activeCategory}
            collapsed={isSidebarCollapsed}
            onSelectCategory={selectCategory}
            onToggleCollapse={toggleSidebar}
          />
          <DevBoardContent
            activeCategory={activeCategory}
            testRunner={testRunner}
            roleView={currentView}
          />
        </section>
        <SettingsModal isOpen={isSettingsOpen} onClose={closeSettings} />

        {/* Cloud Shell - Desktop only, dev view only */}
        {currentView === 'dev' && (
          <>
            <ShellFab onClick={() => setIsShellOpen(true)} />
            <ShellModal isOpen={isShellOpen} onClose={() => setIsShellOpen(false)} />
          </>
        )}
      </div>
    </TestCountProvider>
  );
}
