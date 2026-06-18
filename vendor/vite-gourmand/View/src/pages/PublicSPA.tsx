/**
 * PublicSPA - Single Page Application for public-facing website
 *
 * This component handles the public site shell while each public page has a real URL.
 */
import { lazy, Suspense, useState, useRef, useEffect, useCallback } from 'react';
import { useLocation, useNavigate } from 'react-router-dom';
import Navbar, { type Page, type UserType } from '../components/layout/Navbar';
import Footer from '../components/layout/Footer';
import PromoBanner from '../components/layout/PromoBanner';
import { PublicDataProvider } from '../contexts/PublicDataContext';
import { NotificationProvider } from '../contexts/NotificationContext';
import { fetchActivePromotions, type ActivePromotion } from '../services/public';
import { confirmNewsletter, unsubscribeNewsletter } from '../services/newsletter';

const HomePage = lazy(() => import('./Home'));
const MenusPage = lazy(() => import('./Menus'));
const ContactPage = lazy(() => import('./Contact'));
const LegalPage = lazy(() => import('./LegalPage'));
const OrderPage = lazy(() => import('./OrderPage'));
const NotificationPanel = lazy(() => import('../components/layout/NotificationPanel'));
const AiAssistantWidget = lazy(() =>
  import('../components/ui/AiAssistantWidget').then((m) => ({ default: m.AiAssistantWidget })),
);

function getSecureSiteOrigin(): string {
  const origin = import.meta.env.VITE_PUBLIC_SITE_URL || 'https://vite-gourmand.fr';

  if (!import.meta.env.PROD) return origin;

  const url = new URL(origin);
  if (url.protocol === 'https:') return url.origin;
  if (url.protocol === 'http:' && ['localhost', '127.0.0.1', '::1'].includes(url.hostname)) {
    return url.origin;
  }

  throw new Error(`VITE_PUBLIC_SITE_URL must use https:// in production. Received: ${origin}`);
}

const SITE_ORIGIN = getSecureSiteOrigin();

interface PublicSPAProps {
  user?: UserType | null;
  onLogout?: () => void;
}

const PAGE_PATHS: Record<Page, string> = {
  home: '/',
  menu: '/menus',
  contact: '/contact',
  order: '/commande',
  'legal-mentions': '/mentions-legales',
  'legal-cgv': '/cgv',
  'user-profile': '/dashboard',
};

const PAGE_TITLES: Record<Page, string> = {
  home: 'Vite & Gourmand - Traiteur artisanal a Bordeaux',
  menu: 'Menus traiteur - Vite & Gourmand',
  contact: 'Contact traiteur a Bordeaux - Vite & Gourmand',
  order: 'Demande de commande - Vite & Gourmand',
  'legal-mentions': 'Mentions legales - Vite & Gourmand',
  'legal-cgv': 'Conditions generales de vente - Vite & Gourmand',
  'user-profile': 'Dashboard - Vite & Gourmand',
};

const PAGE_DESCRIPTIONS: Record<Page, string> = {
  home: 'Vite & Gourmand, traiteur artisanal a Bordeaux pour mariages, receptions privees et evenements professionnels.',
  menu: 'Decouvrez les menus traiteur Vite & Gourmand pour vos receptions, mariages et evenements professionnels a Bordeaux.',
  contact:
    'Contactez Vite & Gourmand pour organiser votre evenement traiteur a Bordeaux et recevoir un devis personnalise.',
  order: 'Preparez votre demande de commande traiteur avec Vite & Gourmand.',
  'legal-mentions': 'Mentions legales de Vite & Gourmand.',
  'legal-cgv': 'Conditions generales de vente de Vite & Gourmand.',
  'user-profile': 'Espace client Vite & Gourmand.',
};

function pageFromPath(pathname: string): Page {
  switch (pathname.replace(/\/$/, '') || '/') {
    case '/menus':
    case '/menu':
      return 'menu';
    case '/commande':
    case '/order':
      return 'order';
    case '/contact':
      return 'contact';
    case '/mentions-legales':
      return 'legal-mentions';
    case '/cgv':
      return 'legal-cgv';
    default:
      return 'home';
  }
}

function updateMeta(name: string, content: string) {
  const selector = `meta[name="${name}"]`;
  let meta = document.head.querySelector<HTMLMetaElement>(selector);
  if (!meta) {
    meta = document.createElement('meta');
    meta.setAttribute('name', name);
    document.head.appendChild(meta);
  }
  meta.setAttribute('content', content);
}

function updateLink(rel: string, href: string) {
  const selector = `link[rel="${rel}"]`;
  let link = document.head.querySelector<HTMLLinkElement>(selector);
  if (!link) {
    link = document.createElement('link');
    link.setAttribute('rel', rel);
    document.head.appendChild(link);
  }
  link.setAttribute('href', href);
}

function PageFallback() {
  return (
    <div className="min-h-[50vh] flex items-center justify-center bg-[#FFF8F0] text-[#722F37] font-semibold">
      Chargement...
    </div>
  );
}

/** Redirect component to avoid side-effects during render */
function RedirectToDashboard() {
  useEffect(() => {
    globalThis.location.href = '/dashboard';
  }, []);
  return null;
}

export default function PublicSPA({ user = null, onLogout }: Readonly<PublicSPAProps>) {
  const location = useLocation();
  const navigate = useNavigate();
  const initialPage = pageFromPath(location.pathname);
  const [currentPage, setCurrentPage] = useState<Page>(initialPage);
  const [isTransitioning, setIsTransitioning] = useState(false);
  const [displayedPage, setDisplayedPage] = useState<Page>(initialPage);
  const [promotions, setPromotions] = useState<ActivePromotion[]>([]);
  const [bannerHeight, setBannerHeight] = useState(0);
  const [orderMenuId, setOrderMenuId] = useState<number | null>(null);
  const [showAssistant, setShowAssistant] = useState(false);
  const [newsletterMsg, setNewsletterMsg] = useState<{
    type: 'success' | 'error';
    text: string;
  } | null>(null);
  const mainRef = useRef<HTMLElement>(null);
  const currentPageRef = useRef<Page>(initialPage);

  useEffect(() => {
    const page = pageFromPath(location.pathname);
    currentPageRef.current = page;
    setCurrentPage(page);
    setDisplayedPage(page);
    setIsTransitioning(false);
  }, [location.pathname]);

  useEffect(() => {
    document.title = PAGE_TITLES[currentPage];
    updateMeta('description', PAGE_DESCRIPTIONS[currentPage]);
    updateLink('canonical', `${SITE_ORIGIN}${PAGE_PATHS[currentPage]}`);
  }, [currentPage]);

  // Handle newsletter confirm/unsubscribe from URL query params
  useEffect(() => {
    const params = new URLSearchParams(globalThis.location.search);
    const action = params.get('newsletter');
    const token = params.get('token');

    if (!action || !token) return;

    // Clean URL
    globalThis.history.replaceState({}, '', globalThis.location.pathname);

    if (action === 'confirm') {
      confirmNewsletter(token)
        .then((res) => setNewsletterMsg({ type: 'success', text: res.message }))
        .catch(() => setNewsletterMsg({ type: 'error', text: 'Token invalide ou expiré.' }));
    } else if (action === 'unsubscribe') {
      unsubscribeNewsletter(token)
        .then((res) => setNewsletterMsg({ type: 'success', text: res.message }))
        .catch(() => setNewsletterMsg({ type: 'error', text: 'Token invalide.' }));
    }
  }, []);

  // Auto-dismiss newsletter message after 8 seconds
  useEffect(() => {
    if (!newsletterMsg) return;
    const timer = setTimeout(() => setNewsletterMsg(null), 8000);
    return () => clearTimeout(timer);
  }, [newsletterMsg]);

  const handleBannerHeightChange = useCallback((h: number) => {
    setBannerHeight(h);
  }, []);

  const handleBannerDismiss = useCallback(() => {
    setBannerHeight(0);
  }, []);

  // Fetch active promotions well after the first interaction window; the banner is not needed for LCP.
  useEffect(() => {
    let cancelled = false;
    const timer = globalThis.setTimeout(() => {
      fetchActivePromotions()
        .then((items) => {
          if (!cancelled) setPromotions(items);
        })
        .catch(() => {
          if (!cancelled) setPromotions([]);
        });
    }, 6500);

    return () => {
      cancelled = true;
      globalThis.clearTimeout(timer);
    };
  }, []);

  useEffect(() => {
    if (currentPage === 'contact') {
      setShowAssistant(false);
      return;
    }
    const timer = globalThis.setTimeout(() => setShowAssistant(true), 9000);
    return () => globalThis.clearTimeout(timer);
  }, [currentPage]);

  // Smooth page transition: fade out → switch → fade in
  const handlePageChange = useCallback(
    (newPage: Page) => {
      if (newPage === 'user-profile') {
        navigate(PAGE_PATHS[newPage]);
        return;
      }
      if (newPage === currentPageRef.current && location.pathname === PAGE_PATHS[newPage]) return;
      currentPageRef.current = newPage;
      setIsTransitioning(true);
      globalThis.setTimeout(() => {
        setCurrentPage(newPage);
        setDisplayedPage(newPage);
        navigate(PAGE_PATHS[newPage]);
        globalThis.scrollTo({ top: 0 });
        requestAnimationFrame(() => {
          setIsTransitioning(false);
        });
      }, 150);
    },
    [location.pathname, navigate],
  );

  // Handler for ordering from menus page
  const handleOrderMenu = useCallback(
    (menuId: number) => {
      setOrderMenuId(menuId);
      handlePageChange('order');
    },
    [handlePageChange],
  );

  // Render the current page content based on internal navigation state
  const renderPage = () => {
    const page = (() => {
      switch (displayedPage) {
        case 'home':
          return <HomePage setCurrentPage={handlePageChange} />;

        case 'menu':
          return (
            <>
              <MenusPage setCurrentPage={handlePageChange} onOrderMenu={handleOrderMenu} />
              <Footer setCurrentPage={handlePageChange} />
            </>
          );

        case 'order':
          return (
            <>
              <OrderPage setCurrentPage={handlePageChange} preSelectedMenuId={orderMenuId} />
              <Footer setCurrentPage={handlePageChange} />
            </>
          );

        case 'contact':
          return (
            <>
              <ContactPage />
              <Footer setCurrentPage={handlePageChange} />
            </>
          );

        case 'legal-mentions':
          return (
            <>
              <LegalPage section="mentions" setCurrentPage={handlePageChange} />
              <Footer setCurrentPage={handlePageChange} />
            </>
          );

        case 'legal-cgv':
          return (
            <>
              <LegalPage section="cgv" setCurrentPage={handlePageChange} />
              <Footer setCurrentPage={handlePageChange} />
            </>
          );

        case 'user-profile':
          return <RedirectToDashboard />;

        default:
          return <HomePage setCurrentPage={handlePageChange} />;
      }
    })();

    return <Suspense fallback={<PageFallback />}>{page}</Suspense>;
  };

  // Total fixed header height = banner + navbar (h-14 = 56px, sm:h-16 = 64px)
  const navHeight = 56; // matches h-14, sm uses 64 but 56 is safe minimum
  const mainContentStyle =
    currentPage === 'home' ? undefined : { paddingTop: `${bannerHeight + navHeight}px` };
  const assistantPageContext =
    currentPage === 'menu' || currentPage === 'order' ? currentPage : 'home';

  return (
    <NotificationProvider enabled={Boolean(user)}>
      <PublicDataProvider>
        <div className="min-h-screen bg-[#FFF8F0]">
          <a
            href="#main-content"
            className="sr-only focus:not-sr-only focus:fixed focus:left-4 focus:top-4 focus:z-[99999] focus:rounded-lg focus:bg-white focus:px-4 focus:py-3 focus:text-sm focus:font-bold focus:text-[#722F37] focus:shadow-xl"
          >
            Aller au contenu principal
          </a>

          {/* Promotional banner — fixed at very top */}
          <PromoBanner
            promotions={promotions}
            onDismiss={handleBannerDismiss}
            onHeightChange={handleBannerHeightChange}
          />

          {/* Navigation — fixed, sits right below the banner */}
          <Navbar
            currentPage={currentPage}
            setCurrentPage={handlePageChange}
            user={user}
            onLogout={onLogout}
            topOffset={bannerHeight}
          />

          {/* Floating notification panel — below navbar */}
          {user && (
            <Suspense fallback={null}>
              <NotificationPanel topOffset={bannerHeight + navHeight} />
            </Suspense>
          )}

          {/* Main content with smooth transition */}
          <main
            id="main-content"
            ref={mainRef}
            tabIndex={-1}
            className={`transition-opacity duration-150 ease-in-out ${
              isTransitioning ? 'opacity-0' : 'opacity-100'
            }`}
            style={mainContentStyle}
          >
            {renderPage()}
          </main>

          {/* Floating AI Assistant — show on all pages except contact (which has its own AI chat) */}
          {showAssistant && currentPage !== 'contact' && (
            <Suspense fallback={null}>
              <AiAssistantWidget
                pageContext={assistantPageContext}
                onNavigateToContact={() => handlePageChange('contact')}
              />
            </Suspense>
          )}

          {/* Newsletter confirmation/unsubscribe toast */}
          {newsletterMsg && (
            <div
              className={`fixed bottom-6 left-1/2 -translate-x-1/2 z-[9999] max-w-md w-[90vw] px-5 py-4 rounded-xl shadow-2xl text-sm font-medium flex items-center gap-3 transition-all duration-300 ${
                newsletterMsg.type === 'success'
                  ? 'bg-emerald-600 text-white'
                  : 'bg-red-600 text-white'
              }`}
            >
              <span>{newsletterMsg.type === 'success' ? '✅' : '❌'}</span>
              <span className="flex-1">{newsletterMsg.text}</span>
              <button
                onClick={() => setNewsletterMsg(null)}
                className="text-white/70 hover:text-white ml-2"
                aria-label="Fermer la notification newsletter"
              >
                ✕
              </button>
            </div>
          )}
        </div>
      </PublicDataProvider>
    </NotificationProvider>
  );
}
