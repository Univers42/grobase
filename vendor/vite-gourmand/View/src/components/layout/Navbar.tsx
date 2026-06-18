import { useState, useEffect } from 'react';
import { User as UserIcon, LogOut, ChefHat, X, Menu, Bell } from 'lucide-react';
import { Button } from '../ui/button';
import { Badge } from '../ui/badge';
import { useNotifications } from '../../contexts/NotificationContext';

export type Page =
  | 'home'
  | 'menu'
  | 'contact'
  | 'order'
  | 'legal-mentions'
  | 'legal-cgv'
  | 'user-profile';

export type UserType = {
  id: string;
  email: string;
  firstName: string;
  lastName: string;
  phone?: string;
  address?: string;
  role: 'user' | 'employee' | 'admin';
};

type NavbarProps = {
  currentPage: Page;
  setCurrentPage: (page: Page) => void;
  user?: UserType | null;
  onLogout?: () => void;
  isDemoMode?: boolean;
  topOffset?: number;
};

interface DesktopAuthActionsProps {
  user: UserType | null;
  isDemoMode: boolean;
  solid: boolean;
  unreadCount: number;
  notificationLabel: string;
  onToggleNotifications: () => void;
  onOpenProfile: () => void;
  onLogout?: () => void;
}

export default function Navbar({
  currentPage,
  setCurrentPage,
  user = null,
  onLogout,
  isDemoMode = false,
  topOffset = 0,
}: Readonly<NavbarProps>) {
  const [mobileMenuOpen, setMobileMenuOpen] = useState(false);
  const [hasScrolled, setHasScrolled] = useState(false);
  const { unreadCount, toggle: toggleNotifications } = useNotifications();

  // On non-home pages, always show solid navbar
  const isHome = currentPage === 'home';
  const solid = hasScrolled || isHome === false;
  const notificationLabel = unreadCount > 0
    ? `Notifications (${unreadCount} non lues)`
    : 'Notifications';

  useEffect(() => {
    const handleScroll = () => setHasScrolled(globalThis.scrollY > 20);
    globalThis.addEventListener('scroll', handleScroll, { passive: true });
    handleScroll();
    return () => globalThis.removeEventListener('scroll', handleScroll);
  }, []);

  useEffect(() => {
    if (mobileMenuOpen) {
      document.body.style.overflow = 'hidden';
    } else {
      document.body.style.overflow = '';
    }
    return () => {
      document.body.style.overflow = '';
    };
  }, [mobileMenuOpen]);

  const navItems = [
    { label: 'Accueil', page: 'home' as Page },
    { label: 'Menus', page: 'menu' as Page },
    { label: 'Contact', page: 'contact' as Page },
  ];

  const handleNavClick = (page: Page) => {
    setCurrentPage(page);
    setMobileMenuOpen(false);
    globalThis.scrollTo({ top: 0, behavior: 'smooth' });
  };

  return (
    <>
      <nav
        aria-label="Navigation principale"
        className={`fixed left-0 right-0 z-50 transition-all duration-200 ${
          solid ? 'bg-white shadow-sm' : 'bg-black/20 backdrop-blur-sm'
        }`}
        style={{ top: `${topOffset}px` }}
      >
        <div className="max-w-6xl mx-auto px-4 sm:px-6">
          <div className="flex justify-between items-center h-14 sm:h-16">
            {/* Logo */}
            <button
              onClick={() => handleNavClick('home')}
              className="flex items-center gap-2 group"
              aria-label="Retourner à l'accueil"
            >
              <div className="w-8 h-8 sm:w-9 sm:h-9 bg-[#722F37] rounded-lg flex items-center justify-center">
                <ChefHat className="h-4 w-4 sm:h-5 sm:w-5 text-white" />
              </div>
              <div className="hidden sm:block">
                <span
                  className={`font-bold text-sm sm:text-base ${solid ? 'text-[#1A1A1A]' : 'text-white'}`}
                >
                  Vite & Gourmand
                </span>
                <span className="block text-[10px] text-[#D4AF37] -mt-0.5">Traiteur</span>
              </div>
            </button>

            {/* Desktop Nav - visible on sm and up */}
            <div className="hidden sm:flex items-center gap-1">
              {navItems.map((item) => (
                <button
                  key={item.page}
                  onClick={() => handleNavClick(item.page)}
                  aria-current={currentPage === item.page ? 'page' : undefined}
                  className={`px-3 py-1.5 rounded-md text-sm font-medium transition-colors ${getDesktopNavItemClass(currentPage === item.page, solid)}`}
                >
                  {item.label}
                </button>
              ))}

              <div className={`w-px h-5 mx-2 ${solid ? 'bg-black/10' : 'bg-white/20'}`} />

              <DesktopAuthActions
                user={user}
                isDemoMode={isDemoMode}
                solid={solid}
                unreadCount={unreadCount}
                notificationLabel={notificationLabel}
                onToggleNotifications={toggleNotifications}
                onOpenProfile={() => handleNavClick('user-profile')}
                onLogout={onLogout}
              />
            </div>

            {/* Mobile menu button */}
            <button
              onClick={() => setMobileMenuOpen(!mobileMenuOpen)}
              className={`sm:hidden p-2 rounded-lg ${solid ? 'text-[#1A1A1A]' : 'text-white'}`}
              aria-label="Ouvrir le menu"
              aria-expanded={mobileMenuOpen}
              aria-controls="mobile-navigation"
            >
              <Menu className="h-5 w-5" />
            </button>
          </div>
        </div>
      </nav>

      {/* Mobile menu */}
      {mobileMenuOpen && (
        <div id="mobile-navigation" className="sm:hidden fixed inset-0 z-50 bg-white flex flex-col">
          <div className="flex items-center justify-between px-4 h-14 border-b flex-shrink-0">
            <div className="flex items-center gap-2">
              <div className="w-8 h-8 bg-[#722F37] rounded-lg flex items-center justify-center">
                <ChefHat className="h-4 w-4 text-white" />
              </div>
              <span className="font-bold text-[#1A1A1A]">Vite & Gourmand</span>
            </div>
            <button
              onClick={() => setMobileMenuOpen(false)}
              className="p-2"
              aria-label="Fermer le menu"
            >
              <X className="h-5 w-5 text-[#1A1A1A]" />
            </button>
          </div>

          <div className="p-4 space-y-2 flex-1 overflow-y-auto">
            {navItems.map((item) => (
              <button
                key={item.page}
                onClick={() => handleNavClick(item.page)}
                aria-current={currentPage === item.page ? 'page' : undefined}
                className={`w-full text-left px-4 py-3 rounded-lg font-medium ${
                  currentPage === item.page
                    ? 'bg-[#722F37] text-white'
                    : 'text-[#1A1A1A] hover:bg-[#FFF8F0]'
                }`}
              >
                {item.label}
              </button>
            ))}
            {user && (
              <button
                data-notification-bell
                onClick={() => {
                  setMobileMenuOpen(false);
                  toggleNotifications();
                }}
                className="w-full text-left px-4 py-3 rounded-lg font-medium text-[#1A1A1A] hover:bg-[#FFF8F0] flex items-center justify-between"
              >
                <span className="flex items-center gap-2">
                  <Bell className="h-4 w-4" />
                  Notifications
                </span>
                {unreadCount > 0 && (
                  <span className="bg-[#722F37] text-white text-[10px] font-bold px-1.5 py-0.5 rounded-full min-w-[18px] text-center">
                    {unreadCount}
                  </span>
                )}
              </button>
            )}
          </div>

          <div className="p-4 border-t bg-[#FFF8F0] flex-shrink-0">
            {user ? (
              <div className="space-y-2">
                <div className="flex items-center gap-3 p-3 bg-white rounded-lg">
                  <div className="w-10 h-10 rounded-full bg-[#722F37] flex items-center justify-center text-white font-bold">
                    {user.firstName.charAt(0)}
                  </div>
                  <div>
                    <p className="font-medium text-[#1A1A1A]">{user.firstName}</p>
                    <p className="text-xs text-[#1A1A1A]/60">{user.email}</p>
                  </div>
                </div>
                {onLogout && (
                  <button
                    onClick={onLogout}
                    className="w-full px-4 py-2 text-red-600 text-sm font-medium text-left"
                  >
                    Déconnexion
                  </button>
                )}
              </div>
            ) : (
              <Button onClick={() => (globalThis.location.href = '/portal')} className="w-full">
                Connexion
              </Button>
            )}
          </div>
        </div>
      )}
    </>
  );
}

function DesktopAuthActions({
  user,
  isDemoMode,
  solid,
  unreadCount,
  notificationLabel,
  onToggleNotifications,
  onOpenProfile,
  onLogout,
}: Readonly<DesktopAuthActionsProps>) {
  if (!user) {
    return (
      <Button
        onClick={() => (globalThis.location.href = '/portal')}
        size="sm"
        className="h-8 px-3 text-xs"
      >
        Connexion
      </Button>
    );
  }

  const canOpenDashboard = user.role === 'admin' || user.role === 'employee';
  return (
    <div className="flex items-center gap-2">
      {isDemoMode && (
        <Badge className="bg-[#722F37] text-white text-[10px] px-2 py-0.5">
          {getRoleLabel(user.role)}
        </Badge>
      )}
      {canOpenDashboard && (
        <button
          onClick={() => (globalThis.location.href = '/dashboard')}
          className={`text-xs px-2 py-1 rounded ${solid ? 'text-[#722F37] hover:bg-[#722F37]/10' : 'text-white hover:bg-white/10'}`}
          aria-label="Ouvrir le dashboard"
        >
          Dashboard
        </button>
      )}
      <button
        data-notification-bell
        onClick={onToggleNotifications}
        className={`relative w-9 h-9 sm:w-7 sm:h-7 rounded-full flex items-center justify-center transition-colors ${
          solid
            ? 'text-[#1A1A1A]/60 hover:bg-[#722F37]/10 hover:text-[#722F37]'
            : 'text-white/70 hover:bg-white/20 hover:text-white'
        }`}
        aria-label={notificationLabel}
      >
        <Bell className="h-4 w-4" />
        {unreadCount > 0 && (
          <span className="absolute -top-0.5 -right-0.5 bg-[#722F37] text-white text-[9px] font-bold min-w-[16px] h-4 rounded-full flex items-center justify-center px-1 ring-2 ring-white">
            {unreadCount > 9 ? '9+' : unreadCount}
          </span>
        )}
      </button>
      <button
        onClick={onOpenProfile}
        className={`w-9 h-9 sm:w-7 sm:h-7 rounded-full flex items-center justify-center ${
          solid ? 'bg-[#FFF8F0] text-[#722F37]' : 'bg-white/20 text-white'
        }`}
        aria-label="Ouvrir mon profil"
      >
        <UserIcon className="h-3.5 w-3.5" />
      </button>
      {onLogout && (
        <button
          onClick={onLogout}
          className={`p-2.5 sm:p-1.5 rounded ${solid ? 'text-[#1A1A1A]/40 hover:text-red-600' : 'text-white/60 hover:text-white'}`}
          aria-label="Se deconnecter"
        >
          <LogOut className="h-4 w-4" />
        </button>
      )}
    </div>
  );
}

function getRoleLabel(role: UserType['role']): string {
  const labels: Record<UserType['role'], string> = {
    admin: 'Admin',
    employee: 'Employé',
    user: 'Client',
  };
  return labels[role];
}

function getDesktopNavItemClass(isCurrentPage: boolean, solid: boolean): string {
  if (isCurrentPage && solid) return 'bg-[#722F37]/10 text-[#722F37]';
  if (isCurrentPage) return 'bg-white/20 text-white';
  if (solid) return 'text-[#1A1A1A]/70 hover:text-[#722F37] hover:bg-[#722F37]/5';
  return 'text-white/80 hover:text-white hover:bg-white/10';
}
