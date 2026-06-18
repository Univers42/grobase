import { useState, useEffect, useRef } from 'react';
import {
  Star,
  ArrowRight,
  ChefHat,
  Award,
  Heart,
  Clock,
  Quote,
  Utensils,
  Users,
  Leaf,
} from 'lucide-react';
import { Button } from '../components/ui/button';
import { Card, CardContent } from '../components/ui/card';
import HeroSection from '../components/layout/HeroSection';
import Footer from '../components/layout/Footer';
import { usePublicData } from '../contexts/PublicDataContext';
import type { ReviewStats, SiteInfo } from '../services/public';

// Page types for internal navigation
export type Page =
  | 'home'
  | 'menu'
  | 'contact'
  | 'order'
  | 'legal-mentions'
  | 'legal-cgv'
  | 'user-profile';

type HomePageProps = {
  setCurrentPage: (page: Page) => void;
};

type Review = {
  id: string;
  userName: string;
  rating: number;
  text: string;
  createdAt: string;
};

/**
 * HomePage - Premium landing page with smooth animations
 *
 * Color scheme from graphical chart:
 * - Deep Bordeaux (#722F37) - Primary brand color
 * - Champagne (#D4AF37) - Accent/highlights
 * - Crème (#FFF8F0) - Light backgrounds
 * - Vert olive (#556B2F) - Success/natural
 * - Noir charbon (#1A1A1A) - Text
 */

// ========================================
// FEATURES SECTION
// ========================================
function FeaturesSection({ yearsOfExperience }: Readonly<{ yearsOfExperience: number }>) {
  const [isVisible, setIsVisible] = useState(false);
  const sectionRef = useRef<HTMLElement>(null);

  useEffect(() => {
    const observer = new IntersectionObserver(
      ([entry]) => {
        if (entry.isIntersecting) {
          setIsVisible(true);
        }
      },
      { threshold: 0.1 },
    );

    if (sectionRef.current) {
      observer.observe(sectionRef.current);
    }

    return () => observer.disconnect();
  }, []);

  const features = [
    {
      icon: ChefHat,
      title: 'Expertise culinaire',
      description: `${yearsOfExperience} années d'expérience au service de votre palais. Une cuisine raffinée et authentique.`,
      color: '#722F37',
    },
    {
      icon: Award,
      title: 'Excellence',
      description:
        'Des produits frais et de saison, sélectionnés avec soin auprès de producteurs locaux.',
      color: '#D4AF37',
    },
    {
      icon: Heart,
      title: 'Sur mesure',
      description:
        'Chaque menu est personnalisé selon vos envies, votre budget et le thème de votre événement.',
      color: '#722F37',
    },
    {
      icon: Clock,
      title: 'Réactivité',
      description:
        "Une équipe disponible et à l'écoute pour répondre à toutes vos demandes rapidement.",
      color: '#556B2F',
    },
  ];

  return (
    <section ref={sectionRef} className="py-12 sm:py-16 lg:py-20 bg-[#FFF8F0]">
      <div className="max-w-[min(90rem,95vw)] mx-auto px-6 sm:px-8 lg:px-12">
        {/* Section header */}
        <div
          className={`text-center max-w-2xl mx-auto mb-10 sm:mb-12 lg:mb-14 transition-all duration-700 ${
            isVisible ? 'opacity-100 translate-y-0' : 'opacity-0 translate-y-8'
          }`}
        >
          <div className="inline-flex items-center gap-2 bg-[#722F37]/10 rounded-full px-4 py-2 mb-4 sm:mb-6">
            <Utensils className="w-4 h-4 text-[#722F37]" />
            <span className="text-[#722F37] text-xs sm:text-sm font-medium">Nos engagements</span>
          </div>
          <h2 className="text-[clamp(1.5rem,4vw,2.5rem)] font-bold text-[#1A1A1A] mb-4 sm:mb-5 leading-tight">
            Pourquoi choisir <span className="text-[#722F37]">Vite & Gourmand</span> ?
          </h2>
          <p className="text-[clamp(0.875rem,1.5vw,1rem)] text-[#5c5c5c] leading-relaxed">
            Notre passion pour la gastronomie et notre engagement envers l'excellence font de chaque
            événement un moment unique.
          </p>
        </div>

        {/* Features grid */}
        <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4 sm:gap-6 lg:gap-[2vw]">
          {features.map((feature, index) => {
            const Icon = feature.icon;
            return (
              <Card
                key={feature.title}
                className={`group bg-white border-0 shadow-sm hover:shadow-xl transition-all duration-500 hover:-translate-y-1 overflow-hidden rounded-2xl ${
                  isVisible ? 'opacity-100 translate-y-0' : 'opacity-0 translate-y-8'
                }`}
                style={{ transitionDelay: `${index * 100}ms` }}
              >
                <CardContent className="p-6 sm:p-8">
                  <div
                    className="w-12 h-12 sm:w-14 sm:h-14 rounded-xl sm:rounded-2xl flex items-center justify-center mb-4 sm:mb-5 transition-transform duration-300 group-hover:scale-110"
                    style={{ backgroundColor: `${feature.color}12` }}
                  >
                    <Icon className="h-5 w-5 sm:h-6 sm:w-6" style={{ color: feature.color }} />
                  </div>
                  <h3 className="text-lg sm:text-xl font-bold text-[#1A1A1A] mb-2 sm:mb-3">
                    {feature.title}
                  </h3>
                  <p className="text-sm text-[#5c5c5c] leading-relaxed">{feature.description}</p>
                </CardContent>
              </Card>
            );
          })}
        </div>
      </div>
    </section>
  );
}

// ========================================
// ABOUT SECTION
// ========================================
function AboutSection({
  setCurrentPage,
  siteInfo,
}: Readonly<{
  setCurrentPage: (page: Page) => void;
  siteInfo: SiteInfo | null;
}>) {
  const ownerNames = siteInfo?.owners?.map((o) => o.firstName).join(' et ') || 'Julie et José';
  const years = siteInfo?.yearsOfExperience ?? 25;
  const [isVisible, setIsVisible] = useState(false);
  const sectionRef = useRef<HTMLElement>(null);

  useEffect(() => {
    const observer = new IntersectionObserver(
      ([entry]) => {
        if (entry.isIntersecting) {
          setIsVisible(true);
        }
      },
      { threshold: 0.1 },
    );

    if (sectionRef.current) {
      observer.observe(sectionRef.current);
    }

    return () => observer.disconnect();
  }, []);

  return (
    <section ref={sectionRef} className="py-12 sm:py-16 lg:py-20 bg-white overflow-hidden">
      <div className="max-w-[min(90rem,95vw)] mx-auto px-6 sm:px-8 lg:px-12">
        <div className="grid grid-cols-1 lg:grid-cols-2 gap-8 lg:gap-[5vw] items-center">
          {/* Image column */}
          <div
            className={`relative order-2 lg:order-1 transition-all duration-1000 ${
              isVisible ? 'opacity-100 translate-x-0' : 'opacity-0 -translate-x-12'
            }`}
          >
            <div className="relative z-10 overflow-hidden sm:overflow-visible">
              <img
                src="/home-team-800.webp"
                alt="Julie et José - Notre équipe"
                className="rounded-2xl sm:rounded-3xl shadow-2xl w-full h-[280px] sm:h-[350px] lg:h-[450px] object-cover"
                loading="lazy"
                decoding="async"
                width={800}
                height={450}
              />
              {/* Floating card */}
              <div className="absolute bottom-2 right-2 sm:bottom-6 sm:right-6 bg-white rounded-xl sm:rounded-2xl shadow-xl p-4 sm:p-5 max-w-[160px] sm:max-w-[180px]">
                <div className="flex items-center gap-2 sm:gap-3 mb-2">
                  <div className="w-8 h-8 sm:w-10 sm:h-10 bg-[#D4AF37]/20 rounded-lg sm:rounded-xl flex items-center justify-center">
                    <Award className="w-4 h-4 sm:w-5 sm:h-5 text-[#D4AF37]" />
                  </div>
                  <span className="text-2xl sm:text-3xl font-bold text-[#722F37]">{years}</span>
                </div>
                <p className="text-xs sm:text-sm text-[#5c5c5c]">Années d'expérience</p>
              </div>
            </div>
            {/* Decorative elements */}
            <div className="absolute -bottom-6 -left-6 w-32 sm:w-48 h-32 sm:h-48 bg-[#722F37]/8 rounded-2xl sm:rounded-3xl -z-10 hidden lg:block" />
            <div className="absolute -top-6 -right-6 w-24 sm:w-32 h-24 sm:h-32 bg-[#D4AF37]/15 rounded-2xl sm:rounded-3xl -z-10 hidden lg:block" />
          </div>

          {/* Text column */}
          <div
            className={`order-1 lg:order-2 space-y-5 sm:space-y-6 transition-all duration-1000 ${
              isVisible ? 'opacity-100 translate-x-0' : 'opacity-0 translate-x-12'
            }`}
            style={{ transitionDelay: '200ms' }}
          >
            <div className="inline-flex items-center gap-2 bg-[#D4AF37]/10 rounded-full px-4 py-2">
              <Heart className="w-4 h-4 text-[#D4AF37]" />
              <span className="text-[#D4AF37] text-xs sm:text-sm font-medium">Notre histoire</span>
            </div>

            <h2 className="text-[clamp(1.5rem,4vw,2.5rem)] font-bold text-[#1A1A1A] leading-tight">
              Une passion
              <br />
              <span className="text-[#722F37]">transmise</span> depuis
              <br />
              deux générations
            </h2>

            <div className="w-12 sm:w-16 h-1 bg-gradient-to-r from-[#722F37] to-[#D4AF37] rounded-full" />

            <div className="space-y-3 sm:space-y-4 text-sm sm:text-base text-[#1A1A1A]/70 leading-relaxed">
              <p>
                Fondée il y a {years} ans à Bordeaux par{' '}
                <strong className="text-[#1A1A1A]">{ownerNames}</strong>, Vite & Gourmand est née
                d'une passion commune pour la gastronomie.
              </p>
              <p>
                Notre duo allie créativité culinaire et sens du détail pour offrir des prestations
                sur mesure qui subliment vos événements.
              </p>
            </div>

            <div className="flex flex-col sm:flex-row gap-3 pt-2 sm:pt-4">
              <Button
                onClick={() => setCurrentPage('contact')}
                size="default"
                className="w-full sm:w-auto justify-center"
              >
                Nous rencontrer
                <ArrowRight className="ml-2 h-4 w-4" />
              </Button>
              <Button
                onClick={() => setCurrentPage('menu')}
                variant="outline"
                size="default"
                className="w-full sm:w-auto justify-center"
              >
                Voir nos menus
              </Button>
            </div>
          </div>
        </div>
      </div>
    </section>
  );
}

// ========================================
// SERVICES SECTION
// ========================================
function ServicesSection({ setCurrentPage }: Readonly<{ setCurrentPage: (page: Page) => void }>) {
  const [isVisible, setIsVisible] = useState(false);
  const sectionRef = useRef<HTMLElement>(null);

  useEffect(() => {
    const observer = new IntersectionObserver(
      ([entry]) => {
        if (entry.isIntersecting) {
          setIsVisible(true);
        }
      },
      { threshold: 0.1 },
    );

    if (sectionRef.current) {
      observer.observe(sectionRef.current);
    }

    return () => observer.disconnect();
  }, []);

  const services = [
    {
      title: 'Mariages',
      description: "De l'apéritif au dessert, un menu sur mesure pour le plus beau jour.",
      image: '/service-wedding-600.webp',
      persons: '30 - 300 personnes',
    },
    {
      title: "Événements d'entreprise",
      description: 'Séminaires, cocktails, team building... Impressionnez vos collaborateurs.',
      image: '/service-corporate-600.webp',
      persons: '10 - 200 personnes',
    },
    {
      title: 'Réceptions privées',
      description: 'Anniversaires, baptêmes, communions... Des moments de partage inoubliables.',
      image: '/service-private-600.webp',
      persons: '10 - 100 personnes',
    },
  ];

  return (
    <section ref={sectionRef} className="py-12 sm:py-16 lg:py-20 bg-[#1A1A1A]">
      <div className="max-w-[min(90rem,95vw)] mx-auto px-6 sm:px-8 lg:px-12">
        {/* Section header */}
        <div
          className={`text-center max-w-2xl mx-auto mb-8 sm:mb-10 lg:mb-12 transition-all duration-700 ${
            isVisible ? 'opacity-100 translate-y-0' : 'opacity-0 translate-y-8'
          }`}
        >
          <div className="inline-flex items-center gap-2 bg-[#D4AF37]/15 rounded-full px-4 py-2 mb-4 sm:mb-6">
            <Users className="w-4 h-4 text-[#D4AF37]" />
            <span className="text-[#D4AF37] text-xs sm:text-sm font-medium">Nos prestations</span>
          </div>
          <h2 className="text-[clamp(1.5rem,4vw,2.5rem)] font-bold text-white mb-4 sm:mb-5">
            Un service adapté à <span className="text-[#D4AF37]">chaque occasion</span>
          </h2>
          <p className="text-[clamp(0.875rem,1.5vw,1rem)] text-white/75">
            Quel que soit votre événement, nous avons la solution pour vous régaler.
          </p>
        </div>

        {/* Services grid */}
        <div className="grid grid-cols-1 sm:grid-cols-2 md:grid-cols-3 gap-4 sm:gap-6 lg:gap-[2vw]">
          {services.map((service, index) => (
            <button
              type="button"
              key={service.title}
              className={`group relative overflow-hidden rounded-2xl sm:rounded-3xl cursor-pointer transition-all duration-700 text-left focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-[#D4AF37] ${
                isVisible ? 'opacity-100 translate-y-0' : 'opacity-0 translate-y-8'
              }`}
              style={{ transitionDelay: `${index * 150}ms` }}
              onClick={() => setCurrentPage('menu')}
              aria-label={`Voir les menus pour ${service.title}`}
            >
              <div className="aspect-[4/5] sm:aspect-[3/4] relative">
                <img
                  src={service.image}
                  alt={service.title}
                  className="w-full h-full object-cover transition-transform duration-700 group-hover:scale-110"
                  loading="lazy"
                  decoding="async"
                />
                <div className="absolute inset-0 bg-gradient-to-t from-[#1A1A1A] via-[#1A1A1A]/50 to-transparent" />

                {/* Content */}
                <div className="absolute inset-x-0 bottom-0 p-5 sm:p-6">
                  <div className="inline-flex items-center gap-2 bg-white/10 backdrop-blur-sm rounded-full px-3 py-1.5 mb-3">
                    <Users className="w-3 h-3 sm:w-3.5 sm:h-3.5 text-[#D4AF37]" />
                    <span className="text-white/80 text-xs">{service.persons}</span>
                  </div>
                  <h3 className="text-xl sm:text-2xl font-bold text-white mb-2">{service.title}</h3>
                  <p className="text-white/60 text-xs sm:text-sm leading-relaxed mb-3 sm:mb-4 line-clamp-2">
                    {service.description}
                  </p>
                  <div className="flex items-center text-[#D4AF37] text-sm font-medium group-hover:gap-3 gap-2 transition-all">
                    <span>Découvrir</span>
                    <ArrowRight className="w-4 h-4 transition-transform group-hover:translate-x-1" />
                  </div>
                </div>
              </div>
            </button>
          ))}
        </div>
      </div>
    </section>
  );
}

// ========================================
// TESTIMONIALS — INFINITE SCROLL CAROUSEL
// ========================================
function TestimonialsSection({
  reviews,
  loading,
  stats,
}: Readonly<{
  reviews: Review[];
  loading: boolean;
  stats: ReviewStats | null;
}>) {
  const [isVisible, setIsVisible] = useState(false);
  const isPausedRef = useRef(false);
  const carouselVisibleRef = useRef(false);
  const pageHiddenRef = useRef(false);
  const sectionRef = useRef<HTMLElement>(null);
  const trackRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const observer = new IntersectionObserver(
      ([entry]) => {
        carouselVisibleRef.current = entry.isIntersecting;
        if (entry.isIntersecting) setIsVisible(true);
      },
      { threshold: 0.1 },
    );
    if (sectionRef.current) observer.observe(sectionRef.current);
    return () => observer.disconnect();
  }, []);

  // Infinite scroll via requestAnimationFrame — runs once, reads isPausedRef
  useEffect(() => {
    if (!trackRef.current || reviews.length === 0) return;
    const reducedMotion = globalThis.matchMedia('(prefers-reduced-motion: reduce)');
    if (reducedMotion.matches) return;

    let offset = 0;
    let animId: number;
    const speed = 0.4; // px per frame (~24px/s at 60fps)

    const handleVisibilityChange = () => {
      pageHiddenRef.current = document.hidden;
    };
    document.addEventListener('visibilitychange', handleVisibilityChange);

    const animate = () => {
      if (!trackRef.current) return;

      if (!isPausedRef.current && !pageHiddenRef.current && carouselVisibleRef.current) {
        offset += speed;
        // Each "set" of reviews is half the scrollWidth (we duplicate once)
        const halfWidth = trackRef.current.scrollWidth / 2;
        if (offset >= halfWidth) offset -= halfWidth; // seamless wrap
        trackRef.current.style.transform = `translateX(-${offset}px)`;
      }

      animId = requestAnimationFrame(animate);
    };

    animId = requestAnimationFrame(animate);
    return () => {
      cancelAnimationFrame(animId);
      document.removeEventListener('visibilitychange', handleVisibilityChange);
    };
  }, [reviews.length]);

  // Duplicate reviews once for seamless loop
  const loopedReviews = [...reviews, ...reviews];

  const avgRating = stats?.averageRating ?? 0;
  const reviewCount = stats?.reviewCount ?? 0;
  const satisfaction = stats?.satisfactionPercent ?? 0;
  const showReviews = loading === false && reviews.length > 0;
  const showEmptyReviews = loading === false && reviews.length === 0;

  return (
    <section ref={sectionRef} className="py-12 sm:py-16 lg:py-20 bg-[#FFF8F0] overflow-hidden">
      {/* ── Header with proud score display ── */}
      <div className="max-w-[min(90rem,95vw)] mx-auto px-6 sm:px-8 lg:px-12 mb-10 sm:mb-14">
        <div
          className={`transition-all duration-700 ${
            isVisible ? 'opacity-100 translate-y-0' : 'opacity-0 translate-y-6'
          }`}
        >
          {/* Section label */}
          <div className="flex justify-center mb-6">
            <div className="inline-flex items-center gap-2 bg-[#722F37]/8 rounded-full px-4 py-2">
              <Quote className="w-4 h-4 text-[#722F37]" />
              <span className="text-[#722F37] text-xs sm:text-sm font-medium tracking-wide">
                Ce que disent nos clients
              </span>
            </div>
          </div>

          {/* Big proud score */}
          <div className="text-center mb-8">
            <h2 className="text-2xl sm:text-3xl lg:text-4xl font-bold text-[#1A1A1A] mb-6">
              Nos clients nous font <span className="text-[#722F37]">confiance</span>
            </h2>

            <div className="flex flex-wrap items-center justify-center gap-6 sm:gap-10">
              {/* Rating badge */}
              <div className="flex flex-col items-center">
                <div className="flex items-center gap-1.5 mb-1.5">
                  <span className="text-4xl sm:text-5xl font-black text-[#1A1A1A] tabular-nums">
                    {avgRating > 0 ? avgRating.toFixed(1) : '–'}
                  </span>
                  <span className="text-xl sm:text-2xl text-[#1A1A1A]/65 font-medium">/5</span>
                </div>
                <div className="flex items-center gap-0.5 mb-1">
                  {[1, 2, 3, 4, 5].map((i) => (
                    <Star
                      key={i}
                      className={`w-5 h-5 sm:w-6 sm:h-6 ${getAverageStarClass(i, avgRating)}`}
                    />
                  ))}
                </div>
                <span className="text-sm text-[#1A1A1A]/65">Note moyenne</span>
              </div>

              {/* Vertical divider */}
              <div className="hidden sm:block w-px h-16 bg-[#1A1A1A]/10" />

              {/* Review count */}
              <div className="flex flex-col items-center">
                <span className="text-4xl sm:text-5xl font-black text-[#722F37] tabular-nums">
                  {reviewCount}
                </span>
                <span className="text-sm text-[#1A1A1A]/65 mt-1">Avis vérifiés</span>
              </div>

              {/* Vertical divider */}
              <div className="hidden sm:block w-px h-16 bg-[#1A1A1A]/10" />

              {/* Satisfaction */}
              <div className="flex flex-col items-center">
                <span className="text-4xl sm:text-5xl font-black text-[#556B2F] tabular-nums">
                  {satisfaction}%
                </span>
                <span className="text-sm text-[#1A1A1A]/65 mt-1">Clients satisfaits</span>
              </div>
            </div>
          </div>
        </div>
      </div>

      {/* ── Infinite scroll carousel ── */}
      {loading && (
        <div className="flex justify-center py-12">
          <div className="w-10 h-10 border-4 border-[#722F37]/20 border-t-[#722F37] rounded-full animate-spin" />
        </div>
      )}
      {showReviews && (
        <section
          className={`relative transition-all duration-700 ${
            isVisible ? 'opacity-100' : 'opacity-0'
          }`}
          style={{ transitionDelay: '300ms' }}
          onMouseEnter={() => {
            isPausedRef.current = true;
          }}
          onMouseLeave={() => {
            isPausedRef.current = false;
          }}
          aria-label="Avis clients — survolez pour mettre en pause le défilement"
        >
          {/* Gradient fade edges */}
          <div className="absolute left-0 top-0 bottom-0 w-16 sm:w-32 bg-gradient-to-r from-[#FFF8F0] to-transparent z-10 pointer-events-none" />
          <div className="absolute right-0 top-0 bottom-0 w-16 sm:w-32 bg-gradient-to-l from-[#FFF8F0] to-transparent z-10 pointer-events-none" />

          {/* Scrolling track (rAF-driven, no CSS animation) */}
          <div
            ref={trackRef}
            className="flex gap-5 will-change-transform"
            style={{ width: 'max-content' }}
          >
            {loopedReviews.map((review, idx) => (
              <article
                key={`${review.id}-${idx}`}
                className="w-[240px] sm:w-[280px] flex-shrink-0 select-none"
              >
                <div className="bg-white rounded-2xl p-5 sm:p-6 h-full border border-[#1A1A1A]/[0.04] shadow-[0_2px_8px_rgba(0,0,0,0.04)] hover:shadow-xl hover:border-[#722F37]/20 transition-all duration-300 hover:-translate-y-1 group">
                  {/* Top row: rating + badge */}
                  <div className="flex items-center justify-between mb-3">
                    <div className="flex items-center gap-0.5">
                      {[1, 2, 3, 4, 5].map((star) => (
                        <Star
                          key={star}
                          className={`w-4 h-4 transition-colors ${
                            star <= review.rating ? 'text-[#D4AF37] fill-[#D4AF37]' : 'text-[#1A1A1A]/8'
                          }`}
                        />
                      ))}
                    </div>
                    {review.rating === 5 && (
                      <span className="text-[10px] font-bold uppercase tracking-wider text-[#D4AF37] bg-[#D4AF37]/10 px-2 py-0.5 rounded-full">
                        Excellent
                      </span>
                    )}
                  </div>

                  {/* Quote with opening mark */}
                  <div className="relative mb-4">
                    <Quote className="absolute -top-1 -left-1 w-6 h-6 text-[#722F37]/10 group-hover:text-[#722F37]/20 transition-colors" />
                    <blockquote className="text-sm text-[#1A1A1A]/75 leading-relaxed pl-4 line-clamp-4">
                      {review.text}
                    </blockquote>
                  </div>

                  {/* Author */}
                  <div className="flex items-center gap-3 pt-3 border-t border-[#1A1A1A]/[0.04]">
                    <div className="w-9 h-9 rounded-full bg-gradient-to-br from-[#722F37] to-[#D4AF37] flex items-center justify-center text-white text-xs font-bold shadow-sm group-hover:shadow-md transition-shadow">
                      {review.userName
                        .split(' ')
                        .map((n) => n[0])
                        .join('')}
                    </div>
                    <div>
                      <span className="font-semibold text-[#1A1A1A] text-sm block">
                        {review.userName}
                      </span>
                      <span className="text-[11px] text-[#1A1A1A]/65">Client vérifié</span>
                    </div>
                  </div>
                </div>
              </article>
            ))}
          </div>
        </section>
      )}
      {showEmptyReviews && (
        <div className="text-center py-12">
          <p className="text-[#1A1A1A]/65 text-sm">Aucun avis pour le moment.</p>
        </div>
      )}
    </section>
  );
}

function getAverageStarClass(starIndex: number, avgRating: number): string {
  if (starIndex <= Math.round(avgRating)) return 'text-[#D4AF37] fill-[#D4AF37]';
  if (starIndex - 0.5 <= avgRating) return 'text-[#D4AF37] fill-[#D4AF37]/50';
  return 'text-[#1A1A1A]/10';
}

// ========================================
// VALUES SECTION
// ========================================
function ValuesSection() {
  const [isVisible, setIsVisible] = useState(false);
  const sectionRef = useRef<HTMLElement>(null);

  useEffect(() => {
    const observer = new IntersectionObserver(
      ([entry]) => {
        if (entry.isIntersecting) {
          setIsVisible(true);
        }
      },
      { threshold: 0.1 },
    );

    if (sectionRef.current) {
      observer.observe(sectionRef.current);
    }

    return () => observer.disconnect();
  }, []);

  const values = [
    {
      icon: Leaf,
      title: 'Produits locaux',
      description:
        'Nous privilégions les circuits courts et les producteurs de la région bordelaise.',
    },
    {
      icon: Heart,
      title: 'Fait maison',
      description: 'Toutes nos préparations sont réalisées dans notre cuisine, avec passion.',
    },
    {
      icon: Award,
      title: 'Qualité premium',
      description: 'Des ingrédients sélectionnés avec soin pour une qualité irréprochable.',
    },
  ];

  return (
    <section ref={sectionRef} className="py-12 sm:py-16 lg:py-20 bg-white">
      <div className="max-w-[min(90rem,95vw)] mx-auto px-6 sm:px-8 lg:px-12">
        <div className="grid grid-cols-1 lg:grid-cols-2 gap-8 lg:gap-[5vw] items-center">
          {/* Values list */}
          <div
            className={`space-y-5 sm:space-y-6 transition-all duration-1000 ${
              isVisible ? 'opacity-100 translate-x-0' : 'opacity-0 -translate-x-12'
            }`}
          >
            <div className="inline-flex items-center gap-2 bg-[#556B2F]/10 rounded-full px-4 py-2">
              <Leaf className="w-4 h-4 text-[#556B2F]" />
              <span className="text-[#556B2F] text-xs sm:text-sm font-medium">Nos valeurs</span>
            </div>

            <h2 className="text-[clamp(1.5rem,4vw,2.5rem)] font-bold text-[#1A1A1A] leading-tight">
              L'engagement d'une
              <br />
              <span className="text-[#556B2F]">cuisine responsable</span>
            </h2>

            <div className="space-y-4 sm:space-y-5">
              {values.map((value, index) => {
                const Icon = value.icon;
                return (
                  <div
                    key={value.title}
                    className={`flex gap-4 transition-all duration-700 ${
                      isVisible ? 'opacity-100 translate-x-0' : 'opacity-0 translate-x-8'
                    }`}
                    style={{ transitionDelay: `${(index + 1) * 150}ms` }}
                  >
                    <div className="w-10 h-10 sm:w-11 sm:h-11 bg-[#556B2F]/10 rounded-xl flex items-center justify-center flex-shrink-0">
                      <Icon className="w-5 h-5 text-[#556B2F]" />
                    </div>
                    <div>
                      <h3 className="font-semibold text-[#1A1A1A] text-base sm:text-lg mb-1">
                        {value.title}
                      </h3>
                      <p className="text-sm text-[#5c5c5c] leading-relaxed">
                        {value.description}
                      </p>
                    </div>
                  </div>
                );
              })}
            </div>
          </div>

          {/* Image */}
          <div
            className={`relative transition-all duration-1000 ${
              isVisible ? 'opacity-100 translate-x-0' : 'opacity-0 translate-x-12'
            }`}
            style={{ transitionDelay: '300ms' }}
          >
            <img
              src="/produce-local-600.webp"
              alt="Produits frais et locaux"
              className="rounded-2xl sm:rounded-3xl shadow-xl w-full h-[280px] sm:h-[350px] lg:h-[400px] object-cover"
              loading="lazy"
              decoding="async"
              width={600}
              height={400}
            />
            <div className="absolute bottom-2 left-2 sm:-bottom-5 sm:-left-5 bg-[#556B2F] text-white rounded-xl sm:rounded-2xl p-3 sm:p-5 shadow-xl">
              <div className="text-2xl sm:text-3xl font-bold mb-0.5">100%</div>
              <p className="text-white/80 text-xs sm:text-sm">
                Produits frais
                <br />
                et de saison
              </p>
            </div>
          </div>
        </div>
      </div>
    </section>
  );
}

// ========================================
// MAIN HOMEPAGE COMPONENT
// ========================================
export default function HomePage({ setCurrentPage }: Readonly<HomePageProps>) {
  const { siteInfo, reviews: rawReviews, reviewStats, loading } = usePublicData();

  // Map DB reviews to the component format
  const reviews: Review[] = rawReviews.map((r) => ({
    id: String(r.id),
    userName: r.User_Publish_user_idToUser?.first_name ?? 'Client',
    rating: r.note,
    text: r.description,
    createdAt: r.created_at,
  }));

  return (
    <div className="min-h-screen bg-[#FFF8F0]">
      <HeroSection
        onExploreMenus={() => setCurrentPage('menu')}
        onContact={() => setCurrentPage('contact')}
        siteInfo={siteInfo}
        reviewStats={reviewStats}
      />
      <FeaturesSection yearsOfExperience={siteInfo?.yearsOfExperience ?? 25} />
      <AboutSection setCurrentPage={setCurrentPage} siteInfo={siteInfo} />
      <ServicesSection setCurrentPage={setCurrentPage} />
      <TestimonialsSection reviews={reviews} loading={loading} stats={reviewStats} />
      <ValuesSection />
      <Footer setCurrentPage={setCurrentPage} />
    </div>
  );
}
