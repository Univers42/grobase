import { Suspense, lazy } from 'react';
import { BrowserRouter, Routes, Route, Navigate } from 'react-router-dom';
import { ToastProvider } from './contexts/ToastContext';
import { ConsentProvider } from './contexts/ConsentContext';
import { CookieBanner } from './components/legal/CookieBanner';
import './App.css';

// Lazy load components
const PublicSPA = lazy(() => import('./pages/PublicSPA'));
const PortalRoute = lazy(() =>
  import('./portal_dashboard/PortalRoutes').then((m) => ({ default: m.PortalRoute })),
);
const ResetPasswordRoute = lazy(() =>
  import('./portal_dashboard/PortalRoutes').then((m) => ({ default: m.ResetPasswordRoute })),
);
const UnauthorizedRoute = lazy(() =>
  import('./portal_dashboard/PortalRoutes').then((m) => ({ default: m.UnauthorizedRoute })),
);
const DashboardRoute = lazy(() =>
  import('./portal_dashboard/PortalRoutes').then((m) => ({ default: m.DashboardRoute })),
);

// Lazy load scenario pages
// const FormTestPage = lazy(() => import('./tests/form').then(m => ({ default: m.FormTestPage })));
const KanbanScenario = lazy(() =>
  import('./scenarios/kanban').then((m) => ({ default: m.KanbanScenario })),
);
const MinitalkScenario = lazy(() =>
  import('./scenarios/minitalk').then((m) => ({ default: m.MinitalkScenario })),
);
const AuthScenario = lazy(() =>
  import('./scenarios/auth').then((m) => ({ default: m.AuthScenario })),
);
const FoodCardScenario = lazy(() =>
  import('./scenarios/FoodCardScenario').then((m) => ({ default: m.FoodCardScenario })),
);

function LoadingSpinner() {
  return (
    <div
      style={{
        minHeight: '100vh',
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
        background: '#f9f9fd',
        color: 'rgba(40, 25, 80, 0.75)',
        fontSize: '18px',
      }}
    >
      ⏳ Chargement...
    </div>
  );
}

function App() {
  return (
    <BrowserRouter>
      <ConsentProvider>
        <ToastProvider>
          <Suspense fallback={<LoadingSpinner />}>
            <Routes>
            {/* Public SPA - crawlable public routes with preserved in-app navigation */}
            <Route path="/" element={<PublicSPA />} />
            <Route path="/menus" element={<PublicSPA />} />
            <Route path="/menu" element={<Navigate to="/menus" replace />} />
            <Route path="/commande" element={<PublicSPA />} />
            <Route path="/order" element={<Navigate to="/commande" replace />} />
            <Route path="/contact" element={<PublicSPA />} />
            <Route path="/mentions-legales" element={<PublicSPA />} />
            <Route path="/cgv" element={<PublicSPA />} />

            {/* Portal & Auth */}
            <Route path="/portal" element={<PortalRoute />} />
            <Route path="/reset-password" element={<ResetPasswordRoute />} />
            <Route path="/unauthorized" element={<UnauthorizedRoute />} />

            {/* Unified Dashboard - SPA with role switching */}
            <Route path="/dashboard" element={<DashboardRoute />} />

            {/* Legacy routes - redirect to dashboard */}
            <Route path="/dev" element={<Navigate to="/dashboard" replace />} />
            <Route path="/admin" element={<Navigate to="/dashboard" replace />} />
            <Route path="/employee" element={<Navigate to="/dashboard" replace />} />

            {/* Scenario pages (dev tools) */}
            {/* <Route path="/scenario/form" element={<FormTestPage />} /> */}
            <Route path="/scenario/foodcard" element={<FoodCardScenario />} />
            <Route path="/scenario/kanban" element={<KanbanScenario />} />
            <Route path="/scenario/minitalk" element={<MinitalkScenario />} />
            <Route path="/scenario/auth" element={<AuthScenario />} />
            </Routes>
          </Suspense>
          <CookieBanner />
        </ToastProvider>
      </ConsentProvider>
    </BrowserRouter>
  );
}

export default App;
