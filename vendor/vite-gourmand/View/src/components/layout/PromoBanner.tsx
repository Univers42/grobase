/**
 * PromoBanner — Sticky top-bar for active promotions
 *
 * Sits above the Navbar with bright attention-grabbing colors.
 * Auto-rotates between active promotions if there are multiple.
 * Dismissible per-session. Includes discount code copy-to-clipboard.
 */
import { useState, useEffect, useCallback, useRef } from 'react';
import { X, ChevronRight, Sparkles, Tag, Copy, Check } from 'lucide-react';
import type { ActivePromotion } from '../../services/public';

interface PromoBannerProps {
  promotions: ActivePromotion[];
  onDismiss?: () => void;
  onHeightChange?: (height: number) => void;
}

export default function PromoBanner({ promotions, onDismiss, onHeightChange }: Readonly<PromoBannerProps>) {
  const [currentIndex, setCurrentIndex] = useState(0);
  const [dismissed, setDismissed] = useState(false);
  const [copied, setCopied] = useState(false);
  const [isVisible, setIsVisible] = useState(false);
  const bannerElRef = useRef<HTMLDivElement>(null);

  // Report height to parent whenever visibility changes
  useEffect(() => {
    if (!isVisible || dismissed || promotions.length === 0) {
      onHeightChange?.(0);
      return;
    }
    // Measure after render + transition
    const timer = setTimeout(() => {
      if (bannerElRef.current) {
        onHeightChange?.(bannerElRef.current.offsetHeight);
      }
    }, 350);
    return () => clearTimeout(timer);
  }, [isVisible, dismissed, promotions.length, onHeightChange]);

  // Fade in on mount
  useEffect(() => {
    if (promotions.length > 0 && !dismissed) {
      const timer = setTimeout(() => setIsVisible(true), 100);
      return () => clearTimeout(timer);
    }
  }, [promotions.length, dismissed]);

  // Auto-rotate every 6s when multiple promotions
  useEffect(() => {
    if (promotions.length <= 1) return;
    const interval = setInterval(() => {
      setCurrentIndex((prev) => (prev + 1) % promotions.length);
    }, 6000);
    return () => clearInterval(interval);
  }, [promotions.length]);

  const copyCode = useCallback((code: string) => {
    navigator.clipboard.writeText(code).then(() => {
      setCopied(true);
      setTimeout(() => setCopied(false), 2000);
    });
  }, []);

  if (dismissed || promotions.length === 0) return null;

  const promo = promotions[currentIndex];
  const discountCode = promo.Discount?.code;

  return (
    <div
      ref={bannerElRef}
      className={`fixed top-0 left-0 right-0 z-[60] transition-all duration-300 overflow-hidden ${
        isVisible ? 'opacity-100' : 'opacity-0 -translate-y-full'
      }`}
      style={{
        background: `linear-gradient(135deg, ${promo.bg_color}, ${adjustBrightness(promo.bg_color, -15)})`,
        color: promo.text_color,
      }}
    >
      {/* Animated shimmer overlay */}
      <div
        className="absolute inset-0 opacity-[0.08] pointer-events-none"
        style={{
          background:
            'linear-gradient(90deg, transparent 0%, rgba(255,255,255,0.4) 50%, transparent 100%)',
          backgroundSize: '200% 100%',
          animation: 'promoShimmer 3s ease-in-out infinite',
        }}
      />

      <div className="relative max-w-[min(90rem,95vw)] mx-auto px-4 sm:px-6 lg:px-12">
        <div className="flex items-center justify-center gap-2 sm:gap-3 py-1 sm:py-1.5 min-h-[28px] sm:min-h-[32px]">
          {/* Sparkle icon */}
          <Sparkles className="w-3 h-3 flex-shrink-0 animate-pulse hidden sm:block" />

          {/* Badge */}
          {promo.badge_text && (
            <span
              className="text-[9px] sm:text-[10px] font-black uppercase tracking-wider px-1.5 py-px rounded-full flex-shrink-0"
              style={{
                backgroundColor: `${promo.text_color}20`,
                border: `1px solid ${promo.text_color}30`,
              }}
            >
              {promo.badge_text}
            </span>
          )}

          {/* Main text */}
          <span className="text-[11px] sm:text-xs font-medium text-center leading-tight line-clamp-1">
            {promo.short_text || promo.title}
          </span>

          {/* Discount code chip */}
          {discountCode && (
            <button
              onClick={() => copyCode(discountCode)}
              className="inline-flex items-center gap-1 text-[10px] sm:text-[11px] font-bold px-1.5 sm:px-2 py-0.5 rounded-md transition-all duration-200 hover:scale-105 flex-shrink-0"
              style={{
                backgroundColor: `${promo.text_color}15`,
                border: `1px dashed ${promo.text_color}40`,
              }}
              title={`Copier le code ${discountCode}`}
            >
              <Tag className="w-3 h-3" />
              <span className="font-mono tracking-wider">{discountCode}</span>
              {copied ? <Check className="w-3 h-3" /> : <Copy className="w-3 h-3 opacity-50" />}
            </button>
          )}

          {/* CTA link */}
          {promo.link_url && promo.link_label && (
            <a
              href={promo.link_url}
              className="hidden md:inline-flex items-center gap-1 text-[11px] font-semibold px-2 py-0.5 rounded-full transition-all duration-200 hover:scale-105 flex-shrink-0"
              style={{
                backgroundColor: promo.text_color,
                color: promo.bg_color,
              }}
            >
              {promo.link_label}
              <ChevronRight className="w-3 h-3" />
            </a>
          )}

          {/* Dots indicator (when multiple promotions) */}
          {promotions.length > 1 && (
            <div className="hidden sm:flex items-center gap-1 ml-2 flex-shrink-0">
              {promotions.map((promotion, i) => (
                <button
                  key={promotion.id}
                  onClick={() => setCurrentIndex(i)}
                  className="w-1.5 h-1.5 rounded-full transition-all duration-300"
                  style={{
                    backgroundColor: promo.text_color,
                    opacity: i === currentIndex ? 1 : 0.3,
                    transform: i === currentIndex ? 'scale(1.3)' : 'scale(1)',
                  }}
                  aria-label={`Voir la promotion : ${promotion.title}`}
                />
              ))}
            </div>
          )}

          {/* Dismiss button */}
          <button
            onClick={() => {
              setIsVisible(false);
              setTimeout(() => {
                setDismissed(true);
                onDismiss?.();
              }, 300);
            }}
            className="absolute right-2 sm:right-4 top-1/2 -translate-y-1/2 p-2 sm:p-1 rounded-full transition-all duration-200 hover:scale-110"
            style={{ backgroundColor: `${promo.text_color}15` }}
            aria-label="Fermer la bannière promotionnelle"
          >
            <X className="w-3.5 h-3.5 sm:w-3 sm:h-3" />
          </button>
        </div>
      </div>

      <style>{`
        @keyframes promoShimmer {
          0% { background-position: -200% 0; }
          100% { background-position: 200% 0; }
        }
      `}</style>
    </div>
  );
}

/** Darken or lighten a hex color by a percentage */
function adjustBrightness(hex: string, percent: number): string {
  const num = Number.parseInt(hex.replace('#', ''), 16);
  const r = Math.min(255, Math.max(0, (num >> 16) + percent));
  const g = Math.min(255, Math.max(0, ((num >> 8) & 0x00ff) + percent));
  const b = Math.min(255, Math.max(0, (num & 0x0000ff) + percent));
  return `#${((r << 16) | (g << 8) | b).toString(16).padStart(6, '0')}`;
}
