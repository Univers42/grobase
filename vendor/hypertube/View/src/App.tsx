import { BrowserRouter, Navigate, Route, Routes } from 'react-router-dom';
import { AuthProvider } from './auth/AuthContext.tsx';
import { RequireAuth } from './auth/RequireAuth.tsx';
import { I18nProvider } from './i18n/I18nContext.tsx';
import { NavBar } from './components/NavBar.tsx';
import { Login } from './pages/Login.tsx';
import { Register } from './pages/Register.tsx';
import { Library } from './pages/Library.tsx';
import { Movie } from './pages/Movie.tsx';
import { Profile } from './pages/Profile.tsx';

/** App composes the providers, the nav bar, and the route table. */
export function App() {
  return (
    <I18nProvider>
      <AuthProvider>
        <BrowserRouter>
          <NavBar />
          <main className="page">
            <Routes>
              <Route path="/login" element={<Login />} />
              <Route path="/register" element={<Register />} />
              <Route path="/library" element={<RequireAuth><Library /></RequireAuth>} />
              <Route path="/movie/:id" element={<RequireAuth><Movie /></RequireAuth>} />
              <Route path="/profile/:userId" element={<RequireAuth><Profile /></RequireAuth>} />
              <Route path="/" element={<Navigate to="/library" replace />} />
              <Route path="*" element={<Navigate to="/library" replace />} />
            </Routes>
          </main>
        </BrowserRouter>
      </AuthProvider>
    </I18nProvider>
  );
}
