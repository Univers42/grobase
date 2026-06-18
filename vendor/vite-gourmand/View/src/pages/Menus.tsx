/**
 * Menus Page — Uber Eats style redesign
 *
 * Features:
 * - Horizontal scrollable category nav (themes) on mobile
 * - Inline image gallery on each card
 * - Full-spec filters: search, price range, theme, dietary, min persons
 * - Menu detail modal with ALL database fields, allergens, conditions
 * - "Commander" button with auth gate → order page
 * - All real data from backend API, zero mocks
 */
import { useState, useMemo, useEffect, useRef, useCallback } from 'react';
import {
  Search,
  Users,
  Euro,
  X,
  ChefHat,
  Clock,
  AlertTriangle,
  SlidersHorizontal,
  UtensilsCrossed,
  ShoppingCart,
  ArrowRight,
  Filter,
  ChevronLeft,
  ChevronRight,
  ImageIcon,
  Leaf,
  Expand,
  Shrink,
} from 'lucide-react';
import { Button } from '../components/ui/button';
import { Input } from '../components/ui/input';
import { Label } from '../components/ui/label';
import { Badge } from '../components/ui/badge';
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '../components/ui/select';
import { useMenus } from '../services/useMenus';
import type { Menu, MenuImage, Dish } from '../services/menus';

const MENU_LOADING_SKELETONS = ['menu-skeleton-1', 'menu-skeleton-2', 'menu-skeleton-3', 'menu-skeleton-4', 'menu-skeleton-5', 'menu-skeleton-6'] as const;
import LazyImage from '../components/ui/LazyImage';
import { useToast } from '../contexts/ToastContext';
import type { Page } from './Home';

/* ── Props ── */
type MenusPageProps = {
  setCurrentPage: (page: Page) => void;
  /** Called when user clicks "Commander" with auth — carries menu numeric ID */
  onOrderMenu?: (menuNumericId: number) => void;
};

/* ── Dietary badge colors ── */
const DIETARY_COLORS: Record<string, string> = {
  vegan: 'bg-green-900 text-white',
  végétarien: 'bg-emerald-900 text-white',
  'sans-gluten': 'bg-amber-600 text-white',
  'sans-lactose': 'bg-purple-600 text-white',
  halal: 'bg-[#722F37] text-white',
  casher: 'bg-indigo-600 text-white',
  bio: 'bg-lime-600 text-white',
  classique: 'bg-[#1A1A1A] text-white',
};

const THEME_ICONS: Record<string, string> = {
  Gastronomie: '🍷',
  Mariage: '💒',
  Entreprise: '🏢',
  Anniversaire: '🎂',
  Végétarien: '🥬',
  Vegan: '🌱',
  Fêtes: '🎄',
  Buffet: '🍽️',
  Cocktail: '🍸',
};

const FALLBACK_IMG = '/menu-fallback-640.webp';

function optimizeCardImageUrl(url: string, width: number) {
  try {
    const imageUrl = new URL(url);
    if (!imageUrl.hostname.includes('images.unsplash.com')) return url;

    imageUrl.searchParams.set('w', String(width));
    imageUrl.searchParams.set('q', '60');
    imageUrl.searchParams.set('auto', 'format');
    imageUrl.searchParams.set('fit', 'crop');
    return imageUrl.toString();
  } catch {
    return url;
  }
}

function useDesktopMenuImages() {
  const [showImages, setShowImages] = useState(() =>
    globalThis.window === undefined
      ? false
      : globalThis.matchMedia('(min-width: 640px)').matches,
  );

  useEffect(() => {
    const media = globalThis.matchMedia('(min-width: 640px)');
    const update = () => setShowImages(media.matches);
    update();
    media.addEventListener('change', update);
    return () => media.removeEventListener('change', update);
  }, []);

  return showImages;
}

/* ══════════════════════════════════════════════════════════
   Inline Image Gallery (mini carousel inside card)
   ══════════════════════════════════════════════════════════ */
function InlineGallery({
  images,
  alt,
  priority = false,
}: Readonly<{
  images: MenuImage[];
  alt: string;
  priority?: boolean;
}>) {
  const [idx, setIdx] = useState(0);
  const srcs =
    images.length > 0
      ? images
      : [
          {
            id: 0,
            menu_id: 0,
            image_url: FALLBACK_IMG,
            alt_text: alt,
            display_order: 0,
            is_primary: true,
          },
        ];
  const count = srcs.length;
  const activeSrc = srcs[idx]?.image_url || FALLBACK_IMG;

  return (
    <div className="relative h-44 sm:h-48 overflow-hidden group/gallery">
      <LazyImage
        src={optimizeCardImageUrl(activeSrc, priority ? 520 : 360)}
        srcSet={`${optimizeCardImageUrl(activeSrc, 320)} 320w, ${optimizeCardImageUrl(activeSrc, 480)} 480w, ${optimizeCardImageUrl(activeSrc, 640)} 640w`}
        sizes="(min-width: 1024px) 320px, (min-width: 640px) 50vw, 100vw"
        alt={srcs[idx]?.alt_text || alt}
        className="w-full h-full"
        width={640}
        height={384}
        loading={priority ? 'eager' : 'lazy'}
        fetchPriority={priority ? 'high' : 'low'}
      />
      {count > 1 && (
        <>
          {/* dots */}
          <div className="absolute bottom-1 left-1/2 -translate-x-1/2 flex gap-0.5">
            {srcs.map((src, i) => (
              <button
                key={`${src.id}-${src.image_url}`}
                onClick={(e) => {
                  e.stopPropagation();
                  setIdx(i);
                }}
                className="w-6 h-6 rounded-full flex items-center justify-center transition-all"
                aria-label={`Image ${i + 1}`}
              >
                <span
                  className={`h-2 rounded-full transition-all ${i === idx ? 'w-4 bg-white' : 'w-2 bg-white/60'}`}
                />
              </button>
            ))}
          </div>
          {/* prev/next */}
          <button
            onClick={(e) => {
              e.stopPropagation();
              setIdx((i) => (i - 1 + count) % count);
            }}
            className="absolute left-1 top-1/2 -translate-y-1/2 bg-white/80 hover:bg-white rounded-full p-2 sm:p-1 opacity-70 sm:opacity-0 group-hover/gallery:opacity-100 transition-opacity"
            aria-label="Image précédente"
          >
            <ChevronLeft className="h-4 w-4 text-[#1A1A1A]" />
          </button>
          <button
            onClick={(e) => {
              e.stopPropagation();
              setIdx((i) => (i + 1) % count);
            }}
            className="absolute right-1 top-1/2 -translate-y-1/2 bg-white/80 hover:bg-white rounded-full p-2 sm:p-1 opacity-70 sm:opacity-0 group-hover/gallery:opacity-100 transition-opacity"
            aria-label="Image suivante"
          >
            <ChevronRight className="h-4 w-4 text-[#1A1A1A]" />
          </button>
        </>
      )}
    </div>
  );
}

/* ══════════════════════════════════════════════════════════
   Full Image Gallery (in detail modal)
   ══════════════════════════════════════════════════════════ */
function FullGallery({ images, alt }: Readonly<{ images: MenuImage[]; alt: string }>) {
  const [idx, setIdx] = useState(0);
  const srcs =
    images.length > 0
      ? images
      : [
          {
            id: 0,
            menu_id: 0,
            image_url: FALLBACK_IMG,
            alt_text: alt,
            display_order: 0,
            is_primary: true,
          },
        ];
  const count = srcs.length;

  return (
    <div className="relative">
      <img
        src={srcs[idx]?.image_url || FALLBACK_IMG}
        alt={srcs[idx]?.alt_text || alt}
        className="w-full h-48 sm:h-64 object-cover"
      />
      <div className="absolute inset-0 bg-gradient-to-t from-[#1A1A1A] via-[#1A1A1A]/40 to-transparent" />

      {count > 1 && (
        <>
          <button
            onClick={() => setIdx((i) => (i - 1 + count) % count)}
            className="absolute left-3 top-1/2 -translate-y-1/2 bg-white/80 hover:bg-white rounded-full p-2.5 sm:p-1.5 shadow"
            aria-label="Image précédente"
          >
            <ChevronLeft className="h-5 w-5 text-[#1A1A1A]" />
          </button>
          <button
            onClick={() => setIdx((i) => (i + 1) % count)}
            className="absolute right-3 top-1/2 -translate-y-1/2 bg-white/80 hover:bg-white rounded-full p-2.5 sm:p-1.5 shadow"
            aria-label="Image suivante"
          >
            <ChevronRight className="h-5 w-5 text-[#1A1A1A]" />
          </button>
          <div className="absolute bottom-3 left-1/2 -translate-x-1/2 flex gap-1.5">
            {srcs.map((src, i) => (
              <button
                key={`${src.id}-${src.image_url}`}
                onClick={() => setIdx(i)}
                className={`w-2 h-2 rounded-full transition-all ${i === idx ? 'bg-white scale-125' : 'bg-white/50'}`}
                aria-label={`Image ${i + 1}`}
              />
            ))}
          </div>
          <div className="absolute top-3 right-3 bg-black/50 text-white text-xs px-2 py-0.5 rounded-full flex items-center gap-1">
            <ImageIcon className="h-3 w-3" />
            {idx + 1}/{count}
          </div>
        </>
      )}
    </div>
  );
}

/* ══════════════════════════════════════════════════════════
   Dish Item (used inside detail modal) — refined design
   ══════════════════════════════════════════════════════════ */
function DishItem({ dish, accentColor }: Readonly<{ dish: Dish; accentColor: string }>) {
  const allergens = dish.DishAllergen?.map((da) => da.Allergen?.name).filter(Boolean) || [];
  return (
    <div className="flex items-start gap-4 py-3 px-4 rounded-xl bg-white border border-[#1A1A1A]/5 hover:border-[#D4AF37]/30 hover:shadow-sm transition-all group/dish">
      {dish.photo_url ? (
        <img
          src={dish.photo_url}
          alt={dish.title}
          className="w-16 h-16 rounded-xl object-cover shrink-0 ring-2 ring-[#1A1A1A]/5 group-hover/dish:ring-[#D4AF37]/30 transition-all"
        />
      ) : (
        <div className="w-16 h-16 rounded-xl shrink-0 bg-gradient-to-br from-[#FFF8F0] to-[#D4AF37]/10 flex items-center justify-center">
          <UtensilsCrossed className="h-6 w-6 text-[#D4AF37]/50" />
        </div>
      )}
      <div className="flex-1 min-w-0">
        <div className="flex items-center gap-2">
          <span
            className="w-2 h-2 rounded-full shrink-0"
            style={{ backgroundColor: accentColor }}
          />
          <p className="text-sm font-semibold text-[#1A1A1A] leading-tight">{dish.title}</p>
        </div>
        {dish.description && (
          <p className="text-xs text-[#1A1A1A]/65 leading-relaxed mt-1.5 ml-4">
            {dish.description}
          </p>
        )}
        {allergens.length > 0 && (
          <div className="flex flex-wrap gap-1.5 mt-2 ml-4">
            {allergens.map((a) => (
              <span
                key={a}
                className="inline-flex items-center gap-1 px-2 py-0.5 bg-amber-50 border border-amber-200 rounded-full text-[10px] font-medium text-amber-700"
              >
                <AlertTriangle className="h-2.5 w-2.5" /> {a}
              </span>
            ))}
          </div>
        )}
      </div>
    </div>
  );
}

/* ══════════════════════════════════════════════════════════
   Menu Detail Modal — Premium full-detail floating window
   Responsive: full-screen on mobile, floating on desktop
   Close via X button, Escape key, or clicking backdrop
   ══════════════════════════════════════════════════════════ */
function MenuDetailModal({
  menu,
  onClose,
  onOrder,
}: Readonly<{
  menu: Menu;
  onClose: () => void;
  onOrder: (menu: Menu) => void;
}>) {
  const [isFullscreen, setIsFullscreen] = useState(false);

  useEffect(() => {
    const handler = (e: KeyboardEvent) => {
      if (e.key === 'Escape') onClose();
    };
    document.addEventListener('keydown', handler);
    document.body.style.overflow = 'hidden';
    return () => {
      document.removeEventListener('keydown', handler);
      document.body.style.overflow = '';
    };
  }, [onClose]);

  // Check for mobile on mount and resize
  useEffect(() => {
    const check = () => setIsFullscreen(globalThis.innerWidth < 640);
    check();
    globalThis.addEventListener('resize', check);
    return () => globalThis.removeEventListener('resize', check);
  }, []);

  const totalMinPrice = (menu.pricePerPerson * menu.minPersons).toFixed(0);
  const totalDishes =
    menu.dishes.entrees.length + menu.dishes.mains.length + menu.dishes.desserts.length;

  return (
    <dialog
      className="fixed inset-0 z-50 m-0 flex max-h-none max-w-none items-end justify-center border-0 bg-black/60 p-0 backdrop-blur-md animate-in fade-in duration-200 sm:items-center"
      onCancel={onClose}
      aria-label={`Détails du menu ${menu.name}`}
      open
    >
      <div
        className={`bg-[#FFF8F0] overflow-hidden shadow-2xl animate-in slide-in-from-bottom-4 duration-300
          ${
            isFullscreen
              ? 'w-full h-full rounded-none'
              : 'rounded-t-3xl sm:rounded-3xl w-full max-w-4xl max-h-[95vh] sm:max-h-[92vh] mx-0 sm:mx-4'
          }`}
      >
        {/* ── Sticky Header Bar ── */}
        <div className="sticky top-0 z-20 bg-[#1A1A1A]/95 backdrop-blur-lg border-b border-white/5 px-4 sm:px-6 py-3 flex items-center justify-between">
          <div className="flex items-center gap-3 min-w-0">
            <div className="w-8 h-8 rounded-full bg-[#722F37] flex items-center justify-center shrink-0">
              <ChefHat className="h-4 w-4 text-[#D4AF37]" />
            </div>
            <div className="min-w-0">
              <h2 className="text-white font-bold text-sm sm:text-base truncate">{menu.name}</h2>
              <p className="text-white/75 text-[10px] sm:text-xs">
                {menu.theme} · {totalDishes} plat{totalDishes > 1 ? 's' : ''}
              </p>
            </div>
          </div>
          <div className="flex items-center gap-2">
            {!isFullscreen && (
              <button
                onClick={() => setIsFullscreen(!isFullscreen)}
                className="hidden sm:flex items-center gap-1 text-white/75 hover:text-white text-xs px-2 py-1 rounded-lg hover:bg-white/10 transition-colors"
                aria-label="Plein écran"
              >
                <Expand className="h-3.5 w-3.5" />
              </button>
            )}
            {isFullscreen && (
              <button
                onClick={() => setIsFullscreen(false)}
                className="flex items-center gap-1 text-white/75 hover:text-white text-xs px-2 py-1 rounded-lg hover:bg-white/10 transition-colors"
                aria-label="Réduire"
              >
                <Shrink className="h-3.5 w-3.5" />
              </button>
            )}
            <button
              onClick={onClose}
              className="bg-white/10 hover:bg-white/20 text-white rounded-full p-2 transition-colors"
              aria-label="Fermer"
            >
              <X className="h-4 w-4" />
            </button>
          </div>
        </div>

        {/* ── Scrollable Content ── */}
        <div
          className={`overflow-y-auto ${isFullscreen ? 'h-[calc(100vh-56px-72px)]' : 'max-h-[calc(92vh-56px-72px)]'}`}
        >
          {/* Hero Image */}
          <div className="relative">
            <FullGallery images={menu.images} alt={menu.name} />
            <div className="absolute inset-0 bg-gradient-to-t from-[#1A1A1A] via-[#1A1A1A]/20 to-transparent" />

            {/* Floating price tag */}
            <div className="absolute top-4 right-4 z-10">
              <div className="bg-white/95 backdrop-blur-sm rounded-2xl px-4 py-2.5 shadow-xl border border-[#D4AF37]/20">
                <p className="text-[10px] text-[#1A1A1A]/65 uppercase tracking-widest font-semibold text-center">
                  Par personne
                </p>
                <p className="text-2xl font-black text-[#722F37] text-center leading-none mt-0.5">
                  {menu.pricePerPerson.toFixed(0)}
                  <span className="text-sm font-semibold ml-0.5">€</span>
                </p>
              </div>
            </div>

            {/* Title overlay */}
            <div className="absolute bottom-0 left-0 right-0 p-5 sm:p-7 z-10">
              <div className="flex flex-wrap gap-2 mb-3">
                <Badge className="bg-[#D4AF37]/90 text-[#1A1A1A] border-0 text-xs font-bold backdrop-blur-sm shadow-sm">
                  {THEME_ICONS[menu.theme] || '🍽️'} {menu.theme}
                </Badge>
                {menu.dietary.map((d) => (
                  <Badge
                    key={d}
                    className={`${DIETARY_COLORS[d] || 'bg-gray-700 text-white'} border-0 text-xs shadow-sm backdrop-blur-sm`}
                  >
                    {d}
                  </Badge>
                ))}
              </div>
              <h2 className="text-2xl sm:text-4xl font-black text-white leading-tight tracking-tight">
                {menu.name}
              </h2>
            </div>
          </div>

          {/* Content Body */}
          <div className="p-5 sm:p-7 lg:p-9 space-y-7">
            {/* Description */}
            <div className="relative">
              <div className="absolute -left-2 sm:-left-4 top-0 bottom-0 w-1 rounded-full bg-gradient-to-b from-[#722F37] via-[#D4AF37] to-[#556B2F]" />
              <p className="text-[#1A1A1A]/75 leading-relaxed text-base sm:text-lg pl-4 sm:pl-5 italic">
                « {menu.description} »
              </p>
            </div>

            {/* CONDITIONS — Prominent warning box */}
            {menu.deliveryNotes && (
              <div className="bg-gradient-to-r from-[#722F37] to-[#8B3A42] rounded-2xl p-5 sm:p-6 text-white shadow-lg shadow-[#722F37]/20 ring-2 ring-[#D4AF37]/40 ring-offset-2 ring-offset-[#FFF8F0]">
                <h3 className="font-bold text-base flex items-center gap-2.5 mb-2">
                  <div className="w-8 h-8 rounded-full bg-[#D4AF37]/20 flex items-center justify-center">
                    <AlertTriangle className="h-4 w-4 text-[#D4AF37]" />
                  </div>
                  Conditions importantes
                </h3>
                <p className="text-white/90 text-sm leading-relaxed pl-10">{menu.deliveryNotes}</p>
              </div>
            )}

            {/* Key Stats Grid */}
            <div className="grid grid-cols-2 sm:grid-cols-4 gap-3 sm:gap-4">
              <div className="bg-white rounded-2xl p-4 sm:p-5 text-center border border-[#1A1A1A]/5 hover:border-[#722F37]/20 hover:shadow-md transition-all group/stat">
                <div className="w-10 h-10 sm:w-12 sm:h-12 rounded-full bg-[#722F37]/10 mx-auto mb-2.5 flex items-center justify-center group-hover/stat:scale-110 transition-transform">
                  <Users className="h-5 w-5 sm:h-6 sm:w-6 text-[#722F37]" />
                </div>
                <p className="text-[9px] sm:text-[10px] text-[#1A1A1A]/65 uppercase tracking-widest font-semibold">
                  Min. convives
                </p>
                <p className="font-black text-xl sm:text-2xl text-[#1A1A1A] mt-0.5">
                  {menu.minPersons}
                </p>
              </div>
              <div className="bg-white rounded-2xl p-4 sm:p-5 text-center border border-[#1A1A1A]/5 hover:border-[#556B2F]/20 hover:shadow-md transition-all group/stat">
                <div className="w-10 h-10 sm:w-12 sm:h-12 rounded-full bg-[#556B2F]/10 mx-auto mb-2.5 flex items-center justify-center group-hover/stat:scale-110 transition-transform">
                  <Euro className="h-5 w-5 sm:h-6 sm:w-6 text-[#556B2F]" />
                </div>
                <p className="text-[9px] sm:text-[10px] text-[#1A1A1A]/65 uppercase tracking-widest font-semibold">
                  Prix / pers.
                </p>
                <p className="font-black text-xl sm:text-2xl text-[#1A1A1A] mt-0.5">
                  {menu.pricePerPerson.toFixed(2)} €
                </p>
              </div>
              <div className="bg-white rounded-2xl p-4 sm:p-5 text-center border border-[#1A1A1A]/5 hover:border-[#D4AF37]/20 hover:shadow-md transition-all group/stat">
                <div className="w-10 h-10 sm:w-12 sm:h-12 rounded-full bg-[#D4AF37]/10 mx-auto mb-2.5 flex items-center justify-center group-hover/stat:scale-110 transition-transform">
                  <ShoppingCart className="h-5 w-5 sm:h-6 sm:w-6 text-[#D4AF37]" />
                </div>
                <p className="text-[9px] sm:text-[10px] text-[#1A1A1A]/65 uppercase tracking-widest font-semibold">
                  Min. total
                </p>
                <p className="font-black text-xl sm:text-2xl text-[#1A1A1A] mt-0.5">
                  {totalMinPrice} €
                </p>
              </div>
              <div className="bg-white rounded-2xl p-4 sm:p-5 text-center border border-[#1A1A1A]/5 hover:border-[#722F37]/20 hover:shadow-md transition-all group/stat">
                <div className="w-10 h-10 sm:w-12 sm:h-12 rounded-full bg-[#722F37]/10 mx-auto mb-2.5 flex items-center justify-center group-hover/stat:scale-110 transition-transform">
                  <Clock className="h-5 w-5 sm:h-6 sm:w-6 text-[#722F37]" />
                </div>
                <p className="text-[9px] sm:text-[10px] text-[#1A1A1A]/65 uppercase tracking-widest font-semibold">
                  Disponibilité
                </p>
                <p
                  className={`font-black text-xl sm:text-2xl mt-0.5 ${menu.stockQuantity <= 5 ? 'text-red-600' : 'text-[#556B2F]'}`}
                >
                  {menu.stockQuantity > 0 ? `${menu.stockQuantity}` : 'Épuisé'}
                </p>
                {menu.stockQuantity > 0 && menu.stockQuantity <= 5 && (
                  <p className="text-[10px] text-red-500 font-medium mt-0.5">Dernières places !</p>
                )}
              </div>
            </div>

            {/* ── Full Composition Section ── */}
            <div>
              <div className="flex items-center gap-3 mb-5">
                <div className="w-10 h-10 rounded-full bg-[#722F37] flex items-center justify-center">
                  <UtensilsCrossed className="h-5 w-5 text-[#D4AF37]" />
                </div>
                <div>
                  <h3 className="text-lg font-bold text-[#1A1A1A]">Composition du menu</h3>
                  <p className="text-xs text-[#1A1A1A]/65">
                    {totalDishes} plat{totalDishes > 1 ? 's' : ''} soigneusement préparés
                  </p>
                </div>
              </div>

              <div className="space-y-5">
                {menu.dishes.entrees.length > 0 && (
                  <div>
                    <div className="flex items-center gap-2 mb-3">
                      <div className="w-6 h-6 rounded-full bg-[#556B2F]/10 flex items-center justify-center">
                        <Leaf className="h-3 w-3 text-[#556B2F]" />
                      </div>
                      <h4 className="text-sm font-bold text-[#556B2F] uppercase tracking-wider">
                        Entrées
                      </h4>
                      <span className="text-[10px] text-[#1A1A1A]/65 font-medium">
                        {menu.dishes.entrees.length} choix
                      </span>
                      <div className="flex-1 h-px bg-[#556B2F]/10" />
                    </div>
                    <div className="space-y-2 ml-1 sm:ml-2">
                      {menu.dishes.entrees.map((d) => (
                        <DishItem key={d.id} dish={d} accentColor="#556B2F" />
                      ))}
                    </div>
                  </div>
                )}
                {menu.dishes.mains.length > 0 && (
                  <div>
                    <div className="flex items-center gap-2 mb-3">
                      <div className="w-6 h-6 rounded-full bg-[#722F37]/10 flex items-center justify-center">
                        <ChefHat className="h-3 w-3 text-[#722F37]" />
                      </div>
                      <h4 className="text-sm font-bold text-[#722F37] uppercase tracking-wider">
                        Plats
                      </h4>
                      <span className="text-[10px] text-[#1A1A1A]/65 font-medium">
                        {menu.dishes.mains.length} choix
                      </span>
                      <div className="flex-1 h-px bg-[#722F37]/10" />
                    </div>
                    <div className="space-y-2 ml-1 sm:ml-2">
                      {menu.dishes.mains.map((d) => (
                        <DishItem key={d.id} dish={d} accentColor="#722F37" />
                      ))}
                    </div>
                  </div>
                )}
                {menu.dishes.desserts.length > 0 && (
                  <div>
                    <div className="flex items-center gap-2 mb-3">
                      <div className="w-6 h-6 rounded-full bg-[#D4AF37]/10 flex items-center justify-center">
                        <span className="text-xs">🍰</span>
                      </div>
                      <h4 className="text-sm font-bold text-[#D4AF37] uppercase tracking-wider">
                        Desserts
                      </h4>
                      <span className="text-[10px] text-[#1A1A1A]/65 font-medium">
                        {menu.dishes.desserts.length} choix
                      </span>
                      <div className="flex-1 h-px bg-[#D4AF37]/10" />
                    </div>
                    <div className="space-y-2 ml-1 sm:ml-2">
                      {menu.dishes.desserts.map((d) => (
                        <DishItem key={d.id} dish={d} accentColor="#D4AF37" />
                      ))}
                    </div>
                  </div>
                )}
              </div>
            </div>

            {/* ── Allergens Summary ── */}
            {menu.allergens.length > 0 && (
              <div className="bg-gradient-to-br from-amber-50 to-orange-50 border border-amber-200 rounded-2xl p-5 sm:p-6">
                <h3 className="text-sm font-bold text-amber-900 mb-3 flex items-center gap-2">
                  <div className="w-8 h-8 rounded-full bg-amber-100 flex items-center justify-center">
                    <AlertTriangle className="h-4 w-4 text-amber-600" />
                  </div>
                  Allergènes présents dans ce menu
                </h3>
                <div className="flex flex-wrap gap-2 ml-10">
                  {menu.allergens.map((a) => (
                    <span
                      key={a}
                      className="px-3 py-1 bg-white border border-amber-300 rounded-full text-xs font-medium text-amber-800 shadow-sm"
                    >
                      {a}
                    </span>
                  ))}
                </div>
              </div>
            )}
          </div>
        </div>

        {/* ── Sticky Footer Actions ── */}
        <div className="sticky bottom-0 z-20 bg-white/95 backdrop-blur-lg border-t border-[#1A1A1A]/5 px-5 sm:px-7 py-4">
          <div className="flex flex-col sm:flex-row gap-3 max-w-4xl mx-auto">
            <Button
              onClick={() => onOrder(menu)}
              size="lg"
              className="flex-1 h-13 sm:h-12 text-base font-bold shadow-lg shadow-[#722F37]/20 hover:shadow-xl hover:shadow-[#722F37]/30 transition-all"
              disabled={menu.stockQuantity === 0}
            >
              {menu.stockQuantity === 0 ? (
                'Menu épuisé'
              ) : (
                <>
                  <ShoppingCart className="h-5 w-5 mr-2" />
                  Commander ce menu — {menu.pricePerPerson.toFixed(0)} €/pers.
                </>
              )}
            </Button>
            <Button
              onClick={onClose}
              variant="outline"
              size="lg"
              className="sm:w-auto h-12 border-[#1A1A1A]/10 hover:bg-[#1A1A1A]/5"
            >
              <X className="h-4 w-4 mr-2" /> Fermer
            </Button>
          </div>
        </div>
      </div>
    </dialog>
  );
}

/* ══════════════════════════════════════════════════════════
   Menu Card — Uber Eats style with inline gallery
   ══════════════════════════════════════════════════════════ */
function MenuCard({
  menu,
  onDetailClick,
  priority = false,
  showImage = true,
}: Readonly<{
  menu: Menu;
  onDetailClick: (m: Menu) => void;
  priority?: boolean;
  showImage?: boolean;
}>) {
  const isLowStock = menu.stockQuantity > 0 && menu.stockQuantity <= 5;
  const isSoldOut = menu.stockQuantity === 0;

  return (
    <article className="group bg-white rounded-2xl border border-[#1A1A1A]/5 overflow-hidden transition-all duration-300 hover:shadow-lg hover:shadow-[#722F37]/8 hover:-translate-y-0.5">
      {showImage && (
        <div className="relative">
          <InlineGallery images={menu.images} alt={menu.name} priority={priority} />
          <div className="absolute inset-0 bg-gradient-to-t from-[#1A1A1A]/50 to-transparent opacity-0 group-hover:opacity-100 transition-opacity duration-300 pointer-events-none" />

          <div className="absolute top-3 left-3 z-[1]">
            <Badge className="bg-white/90 text-[#1A1A1A] border-0 text-xs backdrop-blur-sm shadow-sm">
              {THEME_ICONS[menu.theme] || '🍽️'} {menu.theme}
            </Badge>
          </div>

          {isLowStock && (
            <Badge className="absolute top-3 right-3 bg-red-600 text-white border-0 text-[10px] shadow z-[1]">
              Plus que {menu.stockQuantity} !
            </Badge>
          )}
          {isSoldOut && (
            <div className="absolute inset-0 bg-[#1A1A1A]/70 flex items-center justify-center z-[1]">
              <span className="text-white font-bold text-lg tracking-wide">Épuisé</span>
            </div>
          )}
        </div>
      )}

      {/* Body */}
      <div className="p-4 sm:p-5">
        {!showImage && (
          <div className="flex flex-wrap items-center gap-2 mb-3">
            <Badge className="bg-[#722F37] text-white border-0 text-xs shadow-sm">
              {THEME_ICONS[menu.theme] || '🍽️'} {menu.theme}
            </Badge>
            {isLowStock && (
              <Badge className="bg-red-700 text-white border-0 text-[10px]">
                Plus que {menu.stockQuantity} !
              </Badge>
            )}
            {isSoldOut && (
              <Badge className="bg-[#1A1A1A] text-white border-0 text-[10px]">Épuisé</Badge>
            )}
          </div>
        )}
        <h3 className="font-bold text-[#1A1A1A] text-lg mb-2 line-clamp-1">{menu.name}</h3>

        <div className="flex flex-wrap gap-1 mb-3">
          {menu.dietary.map((d) => (
            <Badge
              key={d}
              className={`${DIETARY_COLORS[d] || 'bg-gray-700 text-white'} border-0 text-[10px] px-2 py-0`}
            >
              {d}
            </Badge>
          ))}
          {menu.allergens.length > 0 && (
            <Badge className="bg-amber-100 text-amber-800 border-amber-200 text-[10px] px-2 py-0">
              ⚠ {menu.allergens.length} allergène{menu.allergens.length > 1 ? 's' : ''}
            </Badge>
          )}
        </div>

        <p className="text-[#1A1A1A]/70 text-sm leading-relaxed line-clamp-2 mb-4">
          {menu.description}
        </p>

        {/* Key metrics */}
        <div className="flex items-center justify-between mb-4 text-sm">
          <div className="flex items-center gap-1.5 text-[#1A1A1A]/65">
            <Users className="h-4 w-4 text-[#722F37]" />
            <span>Min. {menu.minPersons} pers.</span>
          </div>
          <div className="flex items-baseline gap-1">
            <span className="text-xl font-bold text-[#722F37]">
              {menu.pricePerPerson.toFixed(0)}
            </span>
            <span className="text-sm text-[#1A1A1A]/65">€/pers.</span>
          </div>
        </div>

        <Button
          className="w-full group/btn"
          disabled={isSoldOut}
          onClick={(e) => {
            e.stopPropagation();
            onDetailClick(menu);
          }}
        >
          {isSoldOut ? (
            'Indisponible'
          ) : (
            <>
              Voir le détail
              <ArrowRight className="h-4 w-4 ml-2 transition-transform group-hover/btn:translate-x-0.5" />
            </>
          )}
        </Button>
      </div>
    </article>
  );
}

/* ══════════════════════════════════════════════════════════
   Horizontal Category Nav (themes) — scrollable on mobile
   ══════════════════════════════════════════════════════════ */
function CategoryNav({
  themes,
  selected,
  onSelect,
}: Readonly<{
  themes: { id: number; name: string }[];
  selected: string;
  onSelect: (t: string) => void;
}>) {
  const scrollRef = useRef<HTMLDivElement>(null);
  const [canScrollLeft, setCanScrollLeft] = useState(false);
  const [canScrollRight, setCanScrollRight] = useState(false);

  const checkScroll = useCallback(() => {
    const el = scrollRef.current;
    if (!el) return;
    setCanScrollLeft(el.scrollLeft > 2);
    setCanScrollRight(el.scrollLeft + el.clientWidth < el.scrollWidth - 2);
  }, []);

  useEffect(() => {
    checkScroll();
    const el = scrollRef.current;
    if (!el) return;
    el.addEventListener('scroll', checkScroll, { passive: true });
    globalThis.addEventListener('resize', checkScroll);
    return () => {
      el.removeEventListener('scroll', checkScroll);
      globalThis.removeEventListener('resize', checkScroll);
    };
  }, [checkScroll, themes]);

  const scroll = (dir: number) => {
    scrollRef.current?.scrollBy({ left: dir * 200, behavior: 'smooth' });
  };

  const allThemes = [{ id: 0, name: 'Tous' }, ...themes];

  return (
    <div className="relative">
      {canScrollLeft && (
        <button
          onClick={() => scroll(-1)}
          className="absolute left-0 top-0 bottom-0 z-10 w-8 bg-gradient-to-r from-[#FFF8F0] to-transparent flex items-center justify-start"
          aria-label="Défiler à gauche"
        >
          <ChevronLeft className="h-4 w-4 text-[#1A1A1A]/65" />
        </button>
      )}
      {canScrollRight && (
        <button
          onClick={() => scroll(1)}
          className="absolute right-0 top-0 bottom-0 z-10 w-8 bg-gradient-to-l from-[#FFF8F0] to-transparent flex items-center justify-end"
          aria-label="Défiler à droite"
        >
          <ChevronRight className="h-4 w-4 text-[#1A1A1A]/65" />
        </button>
      )}

      <div
        ref={scrollRef}
        className="flex gap-2 overflow-x-auto scrollbar-hide py-1 px-1 -mx-1"
        style={{ scrollbarWidth: 'none', msOverflowStyle: 'none' }}
      >
        {allThemes.map((t) => {
          const isActive = selected === t.name || (selected === '' && t.name === 'Tous');
          return (
            <button
              key={t.id}
              onClick={() => onSelect(t.name === 'Tous' ? '' : t.name)}
              className={`shrink-0 px-4 py-2 rounded-full text-sm font-medium transition-all whitespace-nowrap
                ${
                  isActive
                    ? 'bg-[#722F37] text-white shadow-md shadow-[#722F37]/20'
                    : 'bg-white text-[#1A1A1A]/70 hover:bg-[#722F37]/10 border border-[#1A1A1A]/10'
                }`}
            >
              {THEME_ICONS[t.name] ? `${THEME_ICONS[t.name]} ` : ''}
              {t.name}
            </button>
          );
        })}
      </div>
    </div>
  );
}

/* ══════════════════════════════════════════════════════════
   Main Menus Page
   ══════════════════════════════════════════════════════════ */
export default function MenusPage({ setCurrentPage, onOrderMenu }: Readonly<MenusPageProps>) {
  const { menus, themes, diets, isLoading, error, refetch } = useMenus({ limit: 6 });
  const { addToast } = useToast();
  const showMenuImages = useDesktopMenuImages();

  const [showFilters, setShowFilters] = useState(false);
  const [selectedMenu, setSelectedMenu] = useState<Menu | null>(null);

  const [searchQuery, setSearchQuery] = useState('');
  const [priceMax, setPriceMax] = useState('');
  const [priceMin, setPriceMin] = useState('');
  const [selectedTheme, setSelectedTheme] = useState('');
  const [selectedDietary, setSelectedDietary] = useState('');
  const [minPeople, setMinPeople] = useState('');

  // Client-side filtering
  const filteredMenus = useMemo(() => {
    let filtered = [...menus];
    if (searchQuery) {
      const q = searchQuery.toLowerCase();
      filtered = filtered.filter(
        (m) =>
          m.name.toLowerCase().includes(q) ||
          m.description.toLowerCase().includes(q) ||
          m.theme.toLowerCase().includes(q),
      );
    }
    if (priceMax) filtered = filtered.filter((m) => m.pricePerPerson <= Number.parseFloat(priceMax));
    if (priceMin) filtered = filtered.filter((m) => m.pricePerPerson >= Number.parseFloat(priceMin));
    if (selectedTheme) filtered = filtered.filter((m) => m.theme === selectedTheme);
    if (selectedDietary && selectedDietary !== 'all')
      filtered = filtered.filter((m) => m.dietary.includes(selectedDietary));
    if (minPeople) filtered = filtered.filter((m) => m.minPersons <= Number.parseInt(minPeople));
    return filtered;
  }, [menus, searchQuery, priceMax, priceMin, selectedTheme, selectedDietary, minPeople]);

  const clearFilters = () => {
    setSearchQuery('');
    setPriceMax('');
    setPriceMin('');
    setSelectedTheme('');
    setSelectedDietary('');
    setMinPeople('');
  };

  const activeFilterCount =
    [searchQuery, priceMax, priceMin, selectedDietary, minPeople].filter(Boolean).length +
    (selectedTheme ? 1 : 0);

  const handleOrder = (menu: Menu) => {
    setSelectedMenu(null);
    if (onOrderMenu) {
      onOrderMenu(menu.numericId);
    } else {
      addToast('Redirection vers la page de commande...', 'info');
      setCurrentPage('order');
    }
  };

  return (
    <div className="min-h-screen bg-[#FFF8F0]">
      {/* Page Header — Premium elegant design */}
      <header className="relative bg-[#1A1A1A] pt-10 pb-14 sm:pt-14 sm:pb-18 overflow-hidden">
        <div className="relative max-w-5xl mx-auto px-4 sm:px-6 text-center">
          {/* Decorative top line */}
          <div className="flex items-center justify-center gap-4 mb-6">
            <div className="w-12 sm:w-20 h-px bg-gradient-to-r from-transparent to-[#D4AF37]/60" />
            <div className="inline-flex items-center gap-2 bg-gradient-to-r from-[#722F37] to-[#8B3A42] rounded-full px-5 py-2 shadow-lg shadow-[#722F37]/20">
              <ChefHat className="h-4 w-4 text-[#D4AF37]" />
              <span className="text-[#D4AF37] text-xs font-bold tracking-[0.2em] uppercase">
                Notre carte
              </span>
            </div>
            <div className="w-12 sm:w-20 h-px bg-gradient-to-l from-transparent to-[#D4AF37]/60" />
          </div>

          <h1 className="text-4xl sm:text-5xl lg:text-6xl font-black text-white mb-4 tracking-tight">
            Nos{' '}
            <span className="text-transparent bg-clip-text bg-gradient-to-r from-[#D4AF37] to-[#E8C547]">
              Menus
            </span>
          </h1>

          <p className="text-white/75 max-w-xl mx-auto text-sm sm:text-base leading-relaxed">
            Des créations culinaires d'exception, pensées pour sublimer chacun de vos événements.
            <br className="hidden sm:block" />
            Filtrez par thème, régime alimentaire ou budget.
          </p>

          {/* Decorative bottom accent */}
          <div className="flex items-center justify-center gap-2 mt-6">
            <div className="w-1.5 h-1.5 rounded-full bg-[#D4AF37]/40" />
            <div className="w-2 h-2 rounded-full bg-[#D4AF37]/60" />
            <div className="w-2.5 h-2.5 rounded-full bg-[#D4AF37]" />
            <div className="w-2 h-2 rounded-full bg-[#D4AF37]/60" />
            <div className="w-1.5 h-1.5 rounded-full bg-[#D4AF37]/40" />
          </div>
        </div>
      </header>

      {/* Content */}
      <div className="max-w-5xl mx-auto px-4 sm:px-6 -mt-5">
        {/* Search + Filters card */}
        <div className="bg-white rounded-2xl shadow-lg shadow-[#1A1A1A]/5 border border-[#1A1A1A]/5 p-4 sm:p-5 mb-4">
          <div className="flex flex-col sm:flex-row gap-3">
            <div className="relative flex-1">
              <Search className="absolute left-3 top-1/2 -translate-y-1/2 h-4 w-4 text-[#1A1A1A]/65" />
              <Input
                type="text"
                placeholder="Rechercher un menu, un thème..."
                value={searchQuery}
                onChange={(e) => setSearchQuery(e.target.value)}
                className="pl-10 h-11 border-[#1A1A1A]/10 focus-visible:ring-[#722F37]"
                aria-label="Rechercher un menu"
              />
            </div>
            <Button
              onClick={() => setShowFilters(!showFilters)}
              variant={showFilters ? 'default' : 'outline'}
              className="h-11 shrink-0"
            >
              <SlidersHorizontal className="h-4 w-4 mr-2" />
              Filtres
              {activeFilterCount > 0 && (
                <span className="ml-2 bg-white text-[#722F37] text-xs font-bold rounded-full w-5 h-5 inline-flex items-center justify-center">
                  {activeFilterCount}
                </span>
              )}
            </Button>
            {activeFilterCount > 0 && (
              <Button
                onClick={clearFilters}
                variant="ghost"
                className="h-11 text-red-600 hover:text-red-700 hover:bg-red-50 shrink-0"
              >
                <X className="h-4 w-4 mr-1" /> Effacer
              </Button>
            )}
          </div>

          {/* Expandable filter panel */}
          <div
            className={`grid transition-all duration-300 ${showFilters ? 'grid-rows-[1fr] opacity-100 mt-4' : 'grid-rows-[0fr] opacity-0'}`}
          >
            <div className="overflow-hidden">
              <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-3 pt-3 border-t border-[#1A1A1A]/5">
                <div>
                  <Label htmlFor="fPriceMin" className="text-xs text-[#5c5c5c] mb-1.5 block">
                    Prix min. (€/pers.)
                  </Label>
                  <Input
                    id="fPriceMin"
                    type="number"
                    value={priceMin}
                    onChange={(e) => setPriceMin(e.target.value)}
                    placeholder="0"
                    min="0"
                    className="h-10 border-[#1A1A1A]/10 focus-visible:ring-[#722F37]"
                  />
                </div>
                <div>
                  <Label htmlFor="fPriceMax" className="text-xs text-[#5c5c5c] mb-1.5 block">
                    Prix max. (€/pers.)
                  </Label>
                  <Input
                    id="fPriceMax"
                    type="number"
                    value={priceMax}
                    onChange={(e) => setPriceMax(e.target.value)}
                    placeholder="100"
                    min="0"
                    className="h-10 border-[#1A1A1A]/10 focus-visible:ring-[#722F37]"
                  />
                </div>
                <div>
                  <Label htmlFor="fDiet" className="text-xs text-[#5c5c5c] mb-1.5 block">
                    Régime alimentaire
                  </Label>
                  <Select value={selectedDietary} onValueChange={setSelectedDietary}>
                    <SelectTrigger id="fDiet" className="h-10 border-[#1A1A1A]/10">
                      <SelectValue placeholder="Tous" />
                    </SelectTrigger>
                    <SelectContent>
                      <SelectItem value="all">Tous les régimes</SelectItem>
                      {diets.map((d) => (
                        <SelectItem key={d.id} value={d.name.toLowerCase()}>
                          <span className="flex items-center gap-1.5">
                            <Leaf className="h-3 w-3 text-green-600" /> {d.name}
                          </span>
                        </SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                </div>
                <div>
                  <Label htmlFor="fPeople" className="text-xs text-[#5c5c5c] mb-1.5 block">
                    Nb personnes max.
                  </Label>
                  <Input
                    id="fPeople"
                    type="number"
                    value={minPeople}
                    onChange={(e) => setMinPeople(e.target.value)}
                    placeholder="10"
                    min="1"
                    className="h-10 border-[#1A1A1A]/10 focus-visible:ring-[#722F37]"
                  />
                </div>
              </div>
            </div>
          </div>
        </div>

        {/* Horizontal scrollable category nav — Uber Eats style */}
        <div className="mb-5 min-h-10">
          {!isLoading && themes.length > 0 && (
            <CategoryNav themes={themes} selected={selectedTheme} onSelect={setSelectedTheme} />
          )}
        </div>

        {/* Loading state */}
        {isLoading && (
          <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-5 sm:gap-6 py-6">
            {MENU_LOADING_SKELETONS.map((skeletonKey) => (
              <div
                key={skeletonKey}
                className={`${showMenuImages ? 'h-[360px]' : 'min-h-[224px]'} rounded-2xl bg-white border border-[#1A1A1A]/5 shadow-sm overflow-hidden`}
              >
                {showMenuImages && <div className="h-44 sm:h-48 bg-[#1A1A1A]/5" />}
                <div className="p-4 sm:p-5 space-y-3">
                  {!showMenuImages && <div className="h-5 w-24 rounded bg-[#722F37]/10" />}
                  <div className="h-5 w-2/3 rounded bg-[#1A1A1A]/10" />
                  <div className="h-3 w-full rounded bg-[#1A1A1A]/10" />
                  <div className="h-3 w-4/5 rounded bg-[#1A1A1A]/10" />
                  <div className="h-10 w-full rounded-lg bg-[#722F37]/10" />
                </div>
              </div>
            ))}
            <span className="sr-only">Chargement des menus...</span>
          </div>
        )}

        {/* Error state */}
        {error && !isLoading && (
          <div className="bg-red-50 border border-red-200 rounded-xl p-6 text-center mb-6">
            <AlertTriangle className="h-8 w-8 text-red-500 mx-auto mb-3" />
            <h3 className="font-bold text-red-900 mb-2">Erreur de chargement</h3>
            <p className="text-red-700 text-sm mb-4">{error}</p>
            <Button onClick={refetch} variant="outline" size="sm">
              Réessayer
            </Button>
          </div>
        )}

        {/* Results */}
        {!isLoading && !error && (
          <>
            <div className="flex items-center justify-between mb-5 px-1">
              <p className="text-sm text-[#1A1A1A]/70">
                <span className="font-bold text-[#1A1A1A]">{filteredMenus.length}</span> menu
                {filteredMenus.length === 1 ? '' : 's'} disponible
                {filteredMenus.length === 1 ? '' : 's'}
              </p>
              {activeFilterCount > 0 && (
                <p className="text-xs text-[#722F37] flex items-center gap-1">
                  <Filter className="h-3 w-3" /> {activeFilterCount} filtre
                  {activeFilterCount > 1 ? 's' : ''} actif{activeFilterCount > 1 ? 's' : ''}
                </p>
              )}
            </div>

            {/* Grid */}
            {filteredMenus.length > 0 ? (
              <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-5 sm:gap-6">
                {filteredMenus.map((menu, index) => (
                  <MenuCard
                    key={menu.id}
                    menu={menu}
                    onDetailClick={setSelectedMenu}
                    priority={index === 0}
                    showImage={showMenuImages}
                  />
                ))}
              </div>
            ) : (
              <div className="text-center py-16">
                <div className="w-16 h-16 mx-auto mb-4 bg-[#1A1A1A]/5 rounded-2xl flex items-center justify-center">
                  <Search className="h-7 w-7 text-[#1A1A1A]/20" />
                </div>
                <h3 className="font-bold text-[#1A1A1A] text-lg mb-2">Aucun menu trouvé</h3>
                <p className="text-[#1A1A1A]/65 text-sm mb-4">
                  {menus.length === 0
                    ? 'Les menus seront bientôt disponibles.'
                    : 'Essayez de modifier vos critères de recherche'}
                </p>
                {activeFilterCount > 0 && (
                  <Button onClick={clearFilters} variant="outline" size="sm">
                    Réinitialiser les filtres
                  </Button>
                )}
              </div>
            )}
          </>
        )}

        {/* Bottom CTA */}
        <div className="mt-12 mb-8 bg-[#1A1A1A] rounded-2xl p-8 sm:p-10 text-center">
          <h2 className="text-xl sm:text-2xl font-bold text-white mb-2">
            Besoin d'un menu personnalisé ?
          </h2>
          <p className="text-white/75 mb-6 max-w-md mx-auto text-sm">
            Notre équipe crée des menus sur mesure adaptés à vos besoins et votre budget.
          </p>
          <Button onClick={() => setCurrentPage('contact')} variant="champagne" size="lg">
            Nous contacter
            <ArrowRight className="h-4 w-4 ml-2" />
          </Button>
        </div>
      </div>

      {/* Detail Modal */}
      {selectedMenu && (
        <MenuDetailModal
          menu={selectedMenu}
          onClose={() => setSelectedMenu(null)}
          onOrder={handleOrder}
        />
      )}
    </div>
  );
}
