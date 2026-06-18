import { Routes, Route, Navigate } from 'react-router-dom';
import { lazy, Suspense } from 'react';
import PublicLayout from '@/components/layout/PublicLayout';
import AdminLayout from '@/components/layout/AdminLayout';
import LoadingScreen from '@/components/ui/LoadingScreen';

// ── Public pages (lazy-loaded) ────────────────────────────────
const Home     = lazy(() => import('@/pages/Home'));
const Animals  = lazy(() => import('@/pages/Animals'));
const Animal   = lazy(() => import('@/pages/AnimalDetail'));
const Events   = lazy(() => import('@/pages/Events'));
const Tickets  = lazy(() => import('@/pages/Tickets'));
const Contact  = lazy(() => import('@/pages/Contact'));

// ── Admin pages (lazy-loaded) ─────────────────────────────────
const Login      = lazy(() => import('@/pages/admin/Login'));
const Dashboard  = lazy(() => import('@/pages/admin/Dashboard'));
const AdminAnimals  = lazy(() => import('@/pages/admin/AdminAnimals'));
const AdminHealth   = lazy(() => import('@/pages/admin/AdminHealth'));
const AdminFeeding  = lazy(() => import('@/pages/admin/AdminFeeding'));
const AdminTickets  = lazy(() => import('@/pages/admin/AdminTickets'));
const AdminEvents   = lazy(() => import('@/pages/admin/AdminEvents'));
const AdminStaff    = lazy(() => import('@/pages/admin/AdminStaff'));
const AdminMessages = lazy(() => import('@/pages/admin/AdminMessages'));

export default function App() {
  return (
    <Suspense fallback={<LoadingScreen />}>
      <Routes>
        {/* Public routes */}
        <Route element={<PublicLayout />}>
          <Route index element={<Home />} />
          <Route path="animals" element={<Animals />} />
          <Route path="animals/:id" element={<Animal />} />
          <Route path="events" element={<Events />} />
          <Route path="tickets" element={<Tickets />} />
          <Route path="contact" element={<Contact />} />
        </Route>

        {/* Dashboard shortcut */}
        <Route path="dashboard" element={<Navigate to="/admin" replace />} />

        {/* Admin routes */}
        <Route path="admin/login" element={<Login />} />
        <Route path="admin" element={<AdminLayout />}>
          <Route index element={<Dashboard />} />
          <Route path="animals" element={<AdminAnimals />} />
          <Route path="health" element={<AdminHealth />} />
          <Route path="feeding" element={<AdminFeeding />} />
          <Route path="tickets" element={<AdminTickets />} />
          <Route path="events" element={<AdminEvents />} />
          <Route path="staff" element={<AdminStaff />} />
          <Route path="messages" element={<AdminMessages />} />
        </Route>
      </Routes>
    </Suspense>
  );
}
