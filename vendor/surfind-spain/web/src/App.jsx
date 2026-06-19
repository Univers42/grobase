import { Routes, Route } from 'react-router-dom';
import { lazy, Suspense } from 'react';
import PublicLayout from '@/components/layout/PublicLayout';
import LoadingScreen from '@/components/ui/LoadingScreen';

const Home = lazy(() => import('@/pages/Home'));
const Beaches = lazy(() => import('@/pages/Beaches'));
const BeachDetail = lazy(() => import('@/pages/BeachDetail'));
const MapPage = lazy(() => import('@/pages/MapPage'));
const Community = lazy(() => import('@/pages/Community'));
const Favorites = lazy(() => import('@/pages/Favorites'));
const Blog = lazy(() => import('@/pages/Blog'));
const Article = lazy(() => import('@/pages/Article'));
const Reportes = lazy(() => import('@/pages/Reportes'));
const Bitacora = lazy(() => import('@/pages/Bitacora'));
const Perfil = lazy(() => import('@/pages/Perfil'));
const Ranking = lazy(() => import('@/pages/Ranking'));
const Login = lazy(() => import('@/pages/Login'));
const Register = lazy(() => import('@/pages/Register'));
const NotFound = lazy(() => import('@/pages/NotFound'));

export default function App() {
  return (
    <Suspense fallback={<LoadingScreen />}>
      <Routes>
        <Route element={<PublicLayout />}>
          <Route index element={<Home />} />
          <Route path="playas" element={<Beaches />} />
          <Route path="playas/:slug" element={<BeachDetail />} />
          <Route path="mapa" element={<MapPage />} />
          <Route path="comunidad" element={<Community />} />
          <Route path="mis-favoritos" element={<Favorites />} />
          <Route path="blog" element={<Blog />} />
          <Route path="blog/:slug" element={<Article />} />
          <Route path="reportes" element={<Reportes />} />
          <Route path="bitacora" element={<Bitacora />} />
          <Route path="perfil" element={<Perfil />} />
          <Route path="ranking" element={<Ranking />} />
          <Route path="acceder" element={<Login />} />
          <Route path="registro" element={<Register />} />
          <Route path="*" element={<NotFound />} />
        </Route>
      </Routes>
    </Suspense>
  );
}
