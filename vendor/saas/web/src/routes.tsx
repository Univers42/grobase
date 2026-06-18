// routes.tsx — the route table. Public pages (landing/auth) load eagerly; the
// dashboard pages are React.lazy and mount under RequireAuth + AppShell so the
// console code-splits away from the marketing/auth entry.

import { lazy } from 'react';
import { createBrowserRouter } from 'react-router-dom';
import { LandingPage } from './pages/landing/LandingPage';
import { LoginPage } from './pages/auth/LoginPage';
import { RegisterPage } from './pages/auth/RegisterPage';
import { ForgotPage } from './pages/auth/ForgotPage';
import { NotFoundPage } from './pages/NotFoundPage';
import { AppShell } from './layout/AppShell';
import { RequireAuth } from './layout/RequireAuth';

const OverviewPage = lazy(() => import('./pages/overview/OverviewPage').then((m) => ({ default: m.OverviewPage })));
const UsersPage = lazy(() => import('./pages/users/UsersPage').then((m) => ({ default: m.UsersPage })));
const InboxPage = lazy(() => import('./pages/inbox/InboxPage').then((m) => ({ default: m.InboxPage })));
const RevenuePage = lazy(() => import('./pages/revenue/RevenuePage').then((m) => ({ default: m.RevenuePage })));
const ContentPage = lazy(() => import('./pages/content/ContentPage').then((m) => ({ default: m.ContentPage })));

/** router is the application route tree consumed by RouterProvider. */
export const router = createBrowserRouter([
  { path: '/', element: <LandingPage /> },
  { path: '/login', element: <LoginPage /> },
  { path: '/register', element: <RegisterPage /> },
  { path: '/forgot', element: <ForgotPage /> },
  {
    path: '/app',
    element: (
      <RequireAuth>
        <AppShell />
      </RequireAuth>
    ),
    children: [
      { index: true, element: <OverviewPage /> },
      { path: 'users', element: <UsersPage /> },
      { path: 'inbox', element: <InboxPage /> },
      { path: 'revenue', element: <RevenuePage /> },
      { path: 'content', element: <ContentPage /> },
    ],
  },
  { path: '*', element: <NotFoundPage /> },
]);
