/**
 * DevBoardContent - Main content area
 * Renders role-specific content based on current view
 */

import { MetricsDashboard } from '../features/qa/metrics';
import { TestCardGrid } from '../features/qa/test-cards';
import { SuiteList, RunAllButton } from '../features/qa/automatic-tests';
import { Overview } from '../features/qa/overview';
import { Activity } from '../features/qa/activity';
import { LogViewer, useRealLogs } from '../features/logs';
import { DatabaseViewer } from '../database';
import type { TestCategory } from '../features/qa/sidebar';
import type { RoleView } from './constants';
import { useMockData } from './useMockData';
import type { useTestRunner } from './useTestRunner';
import { VerboseOutput } from './VerboseOutput';
// Admin widgets
import {
  AdminOverview,
  AdminOrders,
  AdminMenu,
  AdminStats,
  AdminSettings,
  AdminTickets,
  AdminAiAgent,
} from '../admin';
// Employee widgets
import { EmployeeOverview, EmployeeOrders, EmployeeTasks, EmployeeProfile } from '../employee';
// Client widgets
import {
  ClientOverview,
  ClientOrders,
  ClientLoyalty,
  ClientSupport,
  ClientReviews,
  ClientProfile,
} from '../client';
import './DevBoardContent.css';

interface DevBoardContentProps {
  activeCategory: TestCategory;
  testRunner: ReturnType<typeof useTestRunner>;
  roleView?: RoleView;
}

const devLabels: Record<TestCategory, string> = {
  overview: 'Overview',
  'test-automatics': 'Tests Automatiques',
  scenarios: 'Scénarios',
  database: 'Database',
  settings: 'Settings',
  logs: 'Live Logs',
  metrics: 'Metrics',
  activity: 'Activity',
};

const adminLabels: Record<TestCategory, string> = {
  overview: 'Tableau de bord',
  'test-automatics': 'Menu Personnalisé',
  scenarios: 'Scénarios',
  database: 'Gestion Menu',
  settings: 'Paramètres',
  logs: 'Tickets',
  metrics: 'Statistiques',
  activity: 'Commandes',
};

const employeeLabels: Record<TestCategory, string> = {
  overview: 'Mon Espace',
  'test-automatics': 'Tests',
  scenarios: 'Tâches',
  database: 'Menus & Plats',
  settings: 'Profil',
  logs: 'Logs',
  metrics: 'Metrics',
  activity: 'Commandes',
};

const clientLabels: Record<TestCategory, string> = {
  overview: 'Mon Espace',
  'test-automatics': 'Tests',
  scenarios: 'Mes Avis',
  database: 'Database',
  settings: 'Mon Profil',
  logs: 'Support',
  metrics: 'Fidélité',
  activity: 'Mes Commandes',
};

function getLabels(roleView: RoleView): Record<TestCategory, string> {
  switch (roleView) {
    case 'admin':
      return adminLabels;
    case 'employee':
      return employeeLabels;
    case 'client':
      return clientLabels;
    default:
      return devLabels;
  }
}

export function DevBoardContent({
  activeCategory,
  testRunner,
  roleView = 'dev',
}: Readonly<DevBoardContentProps>) {
  const { tests } = useMockData(activeCategory);
  const { autoTests, suites, metrics, isRunning, runAll, runSuite, runType, rawOutput, error } =
    testRunner;
  const { logs, connected, clear } = useRealLogs();

  const labels = getLabels(roleView);

  // Dev view specific features
  const isDev = roleView === 'dev';
  const isClient = roleView === 'client';
  const showMetricsDashboard = isDev && activeCategory === 'test-automatics';
  const showRunAllButton = isDev && activeCategory === 'test-automatics';
  const showCliOutput = isDev && activeCategory === 'test-automatics';

  return (
    <main className="devboard-content">
      {/* Error banner for backend connectivity issues (dev view only) */}
      {error && isDev && activeCategory === 'test-automatics' && (
        <div
          style={{
            padding: 'var(--space-4)',
            marginBottom: 'var(--space-4)',
            background: 'var(--color-error-bg)',
            border: '1px solid var(--color-error-border)',
            borderRadius: 'var(--radius-md)',
            color: 'var(--color-error-text)',
            display: 'flex',
            alignItems: 'center',
            gap: 'var(--space-2)',
          }}
        >
          <span style={{ fontSize: '1.25rem' }}>⚠️</span>
          <div>
            <strong>Error: </strong>
            {error}
            {error.includes('Backend') && (
              <div style={{ fontSize: 'var(--font-size-sm)', marginTop: 'var(--space-1)' }}>
                Run:{' '}
                <code
                  style={{
                    background: 'rgba(0,0,0,0.1)',
                    padding: '2px 6px',
                    borderRadius: 'var(--radius-sm)',
                    fontFamily: 'monospace',
                  }}
                >
                  cd backend && npm run start:dev
                </code>
              </div>
            )}
          </div>
        </div>
      )}

      {showMetricsDashboard && (
        <section className="devboard-content-metrics">
          <MetricsDashboard
            totalTests={metrics.total}
            passedTests={metrics.passed}
            failedTests={metrics.failed}
            passRate={Math.max(0, metrics.passRate)}
            isLoading={isRunning}
          />
        </section>
      )}

      <section className="devboard-content-main">
        {!isClient && (
          <header className="devboard-content-header">
            <h2 className="devboard-content-title">{labels[activeCategory]}</h2>
            <div className="devboard-content-actions">
              {showRunAllButton && (
                <RunAllButton count={autoTests.length} onRun={runAll} isRunning={isRunning} />
              )}
            </div>
          </header>
        )}

        <div className="devboard-cards-container">
          {renderContent({
            roleView,
            category: activeCategory,
            tests,
            suites,
            logs,
            connected,
            clear,
            metrics,
            isRunning,
            runSuite,
            runType,
          })}
        </div>

        {showCliOutput && <VerboseOutput output={rawOutput} isVisible={true} />}
      </section>
    </main>
  );
}

interface RenderContentContext {
  roleView: RoleView;
  category: TestCategory;
  tests: ReturnType<typeof useMockData>['tests'];
  suites: ReturnType<typeof useTestRunner>['suites'];
  logs: ReturnType<typeof useRealLogs>['logs'];
  connected: boolean;
  clear: () => void;
  metrics: ReturnType<typeof useTestRunner>['metrics'];
  isRunning: boolean;
  runSuite: ReturnType<typeof useTestRunner>['runSuite'];
  runType: ReturnType<typeof useTestRunner>['runType'];
}

type RenderDevContentContext = Omit<RenderContentContext, 'roleView'>;

function renderContent(context: RenderContentContext) {
  const { roleView, category } = context;
  // Route to role-specific content
  switch (roleView) {
    case 'admin':
      return renderAdminContent(category);
    case 'employee':
      return renderEmployeeContent(category);
    case 'client':
      return renderClientContent(category);
    default:
      return renderDevContent(context);
  }
}

function renderDevContent({
  category,
  tests,
  suites,
  logs,
  connected,
  clear,
  metrics,
  isRunning,
  runSuite,
  runType,
}: RenderDevContentContext) {
  switch (category) {
    case 'overview':
      return <Overview metrics={metrics} isRunning={isRunning} />;
    case 'scenarios':
      return <TestCardGrid tests={tests} />;
    case 'database':
      return <DatabaseViewer />;
    case 'logs':
      return <LogViewer logs={logs} connected={connected} onClear={clear} />;
    case 'activity':
      return <Activity />;
    default:
      return (
        <SuiteList
          suites={suites}
          onRunSuite={runSuite}
          onRunType={runType}
          isRunning={isRunning}
        />
      );
  }
}

function renderAdminContent(category: TestCategory) {
  switch (category) {
    case 'overview':
      return <AdminOverview />;
    case 'activity':
      return <AdminOrders />;
    case 'database':
      return <AdminMenu />;
    case 'test-automatics':
      return <AdminAiAgent />;
    case 'logs':
      return <AdminTickets />;
    case 'metrics':
      return <AdminStats />;
    case 'settings':
      return <AdminSettings />;
    default:
      return <AdminOverview />;
  }
}

function renderEmployeeContent(category: TestCategory) {
  switch (category) {
    case 'overview':
      return <EmployeeOverview />;
    case 'activity':
      return <EmployeeOrders />;
    case 'database':
      return <DatabaseViewer initialTable="Menu" />;
    case 'scenarios':
      return <EmployeeTasks />;
    case 'settings':
      return <EmployeeProfile />;
    default:
      return <EmployeeOverview />;
  }
}

function renderClientContent(category: TestCategory) {
  switch (category) {
    case 'overview':
      return <ClientOverview />;
    case 'activity':
      return <ClientOrders />;
    case 'metrics':
      return <ClientLoyalty />;
    case 'logs':
      return <ClientSupport />;
    case 'scenarios':
      return <ClientReviews />;
    case 'settings':
      return <ClientProfile />;
    default:
      return <ClientOverview />;
  }
}
