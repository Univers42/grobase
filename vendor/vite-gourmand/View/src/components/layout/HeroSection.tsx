import { useEffect, useState } from 'react';
import { ArrowRight, Phone, Star, Award, Users, Calendar, Sparkles } from 'lucide-react';
import { Button } from '../ui/button';
import type { ReviewStats, SiteInfo } from '../../services/public';

const HERO_IMAGE_SRC = '/hero-catering-1280.webp';
const HERO_IMAGE_SRCSET = [960, 1280, 1920]
  .map((width) => `/hero-catering-${width}.webp ${width}w`)
  .join(', ');

interface HeroSectionProps {
  onExploreMenus: () => void;
  onContact: () => void;
  siteInfo?: SiteInfo | null;
  reviewStats?: ReviewStats | null;
}

function getHeroDisplayData(siteInfo?: SiteInfo | null, reviewStats?: ReviewStats | null) {
  const years = siteInfo?.yearsOfExperience ?? 25;
  const eventCount = siteInfo?.eventCount ?? 0;
  const avgRating = reviewStats?.averageRating ?? 0;
  const reviewCount = reviewStats?.reviewCount ?? 0;
  const satisfaction = reviewStats?.satisfactionPercent ?? 0;
  const ownerNames = siteInfo?.owners?.map((owner) => owner.firstName).join(' et ') || 'Julie et José';

  return {
    years,
    eventCount,
    avgRating,
    reviewCount,
    satisfaction,
    ownerNames,
    eventValue: eventCount > 0 ? `${eventCount}+` : '–',
    satisfactionValue: satisfaction > 0 ? `${satisfaction}%` : '–',
    ratingValue: avgRating > 0 ? `${avgRating.toFixed(1)}/5` : '–',
    reviewLabel: reviewCount > 0 ? `${reviewCount} avis clients vérifiés` : 'Avis clients vérifiés',
    testimonialText: reviewCount > 0
      ? 'Découvrez les avis de nos clients satisfaits !'
      : 'Soyez le premier à laisser un avis !',
  };
}

/**
 * HeroSection - Premium landing section with smooth animations
 *
 * Color scheme from graphical chart:
 * - Deep Bordeaux (#722F37) - Primary brand color
 * - Champagne (#D4AF37) - Accent/highlights
 * - Crème (#FFF8F0) - Light backgrounds
 * - Vert olive (#556B2F) - Success/natural
 * - Noir charbon (#1A1A1A) - Text
 */
export default function HeroSection({
  onExploreMenus,
  onContact,
  siteInfo,
  reviewStats,
}: Readonly<HeroSectionProps>) {
  const [mounted, setMounted] = useState(false);

  useEffect(() => {
    setMounted(true);
  }, []);

  const hero = getHeroDisplayData(siteInfo, reviewStats);

  return (
    <section className="relative min-h-[100svh] flex items-center overflow-hidden bg-[#1A1A1A]">
      {/* Background image is rendered as an img so the browser can prioritize the LCP asset. */}
      <div className="absolute inset-0 overflow-hidden">
        <img
          src={HERO_IMAGE_SRC}
          srcSet={HERO_IMAGE_SRCSET}
          sizes="100vw"
          alt="Buffet traiteur gastronomique prepare pour une reception"
          width={1920}
          height={1280}
          loading="eager"
          fetchPriority="high"
          decoding="async"
          className="absolute inset-0 h-full w-full scale-[1.02] object-cover object-center"
        />
        {/* Multi-layer overlay for depth */}
        <div className="absolute inset-0 bg-gradient-to-r from-[#1A1A1A] via-[#1A1A1A]/85 to-[#1A1A1A]/50" />
        <div className="absolute inset-0 bg-gradient-to-t from-[#1A1A1A] via-transparent to-[#1A1A1A]/40" />
        <div className="absolute inset-0 bg-[#722F37]/10 mix-blend-multiply" />
      </div>

      {/* Animated decorative elements */}
      <div className="absolute inset-0 overflow-hidden pointer-events-none">
        <div
          className={`absolute top-1/4 right-1/4 w-[500px] h-[500px] bg-[#D4AF37]/8 rounded-full blur-[100px] transition-all duration-1000 ${
            mounted ? 'opacity-100 scale-100' : 'opacity-0 scale-50'
          }`}
          style={{ transitionDelay: '300ms' }}
        />
        <div
          className={`absolute bottom-1/4 left-1/4 w-[400px] h-[400px] bg-[#722F37]/15 rounded-full blur-[100px] transition-all duration-1000 ${
            mounted ? 'opacity-100 scale-100' : 'opacity-0 scale-50'
          }`}
          style={{ transitionDelay: '500ms' }}
        />
      </div>

      {/* Content */}
      <div className="relative z-10 w-full max-w-[min(90rem,95vw)] mx-auto px-6 sm:px-8 lg:px-12 pt-28 sm:pt-32 pb-16 sm:pb-20">
        <div className="grid lg:grid-cols-12 gap-8 lg:gap-[4vw] items-center">
          {/* Left column - Text content (7 cols) */}
          <div className="lg:col-span-7 space-y-6 sm:space-y-8">
            {/* Badge */}
            <div
              className={`inline-flex items-center gap-2 sm:gap-3 bg-[#D4AF37]/15 backdrop-blur-md border border-[#D4AF37]/30 rounded-full px-4 py-2 transition-all duration-700 ${
                mounted ? 'opacity-100 translate-y-0' : 'opacity-0 translate-y-4'
              }`}
            >
              <Sparkles className="w-4 h-4 text-[#D4AF37] animate-pulse" />
              <span className="text-[#D4AF37] text-xs sm:text-sm font-medium tracking-wide">
                Traiteur d'exception à Bordeaux
              </span>
            </div>

            {/* Main title */}
            <div
              className={`space-y-3 sm:space-y-4 transition-all duration-700 ${
                mounted ? 'opacity-100 translate-y-0' : 'opacity-0 translate-y-6'
              }`}
              style={{ transitionDelay: '150ms' }}
            >
              <h1 className="text-[clamp(2rem,6vw,4rem)] font-bold text-white leading-[1.1] tracking-tight">
                <span className="block">L'art de la</span>
                <span className="block bg-gradient-to-r from-[#D4AF37] to-[#f0d78c] bg-clip-text text-transparent">
                  gastronomie
                </span>
                <span className="block">française</span>
              </h1>
              <div className="w-16 sm:w-20 lg:w-[5vw] h-1 bg-gradient-to-r from-[#722F37] to-[#D4AF37] rounded-full" />
            </div>

            {/* Subtitle */}
            <p
              className={`text-[clamp(0.9rem,1.5vw,1.25rem)] text-white/75 max-w-xl leading-relaxed transition-all duration-700 ${
                mounted ? 'opacity-100 translate-y-0' : 'opacity-0 translate-y-6'
              }`}
              style={{ transitionDelay: '300ms' }}
            >
              {hero.ownerNames} mettent leur{' '}
              <span className="text-[#D4AF37] font-medium">{hero.years} années d'expertise</span> au
              service de vos événements. Une cuisine raffinée, des moments inoubliables.
            </p>

            {/* CTA Buttons */}
            <div
              className={`flex flex-col sm:flex-row gap-3 sm:gap-4 pt-2 transition-all duration-700 ${
                mounted ? 'opacity-100 translate-y-0' : 'opacity-0 translate-y-6'
              }`}
              style={{ transitionDelay: '450ms' }}
            >
              <Button
                onClick={onExploreMenus}
                size="lg"
                className="group w-full sm:w-auto justify-center text-sm sm:text-base h-12 sm:h-14 px-6 sm:px-8"
              >
                Découvrir nos menus
                <ArrowRight className="ml-2 h-4 w-4 sm:h-5 sm:w-5 transition-transform group-hover:translate-x-1" />
              </Button>
              <Button
                onClick={onContact}
                variant="outlineLight"
                size="lg"
                className="w-full sm:w-auto justify-center text-sm sm:text-base h-12 sm:h-14 px-6 sm:px-8"
              >
                <Phone className="mr-2 h-4 w-4 sm:h-5 sm:w-5" />
                Nous contacter
              </Button>
            </div>

            {/* Trust indicators */}
            <div
              className={`flex flex-col sm:flex-row sm:items-center gap-4 sm:gap-6 pt-4 sm:pt-6 transition-all duration-700 ${
                mounted ? 'opacity-100 translate-y-0' : 'opacity-0 translate-y-6'
              }`}
              style={{ transitionDelay: '600ms' }}
            >
              <div className="flex items-center gap-4">
                <div className="flex -space-x-2.5">
                  {['JD', 'ML', 'PB', 'AS'].map((initials) => (
                    <div
                      key={initials}
                      className="w-9 h-9 sm:w-10 sm:h-10 rounded-full border-2 border-[#1A1A1A] bg-gradient-to-br from-[#D4AF37]/90 to-[#722F37] flex items-center justify-center text-white text-xs font-medium shadow-lg"
                    >
                      {initials}
                    </div>
                  ))}
                </div>
                <div>
                  <div className="flex items-center gap-1">
                    {[1, 2, 3, 4, 5].map((starValue) => (
                      <Star
                        key={starValue}
                        className={`w-3.5 h-3.5 sm:w-4 sm:h-4 ${starValue <= Math.round(hero.avgRating) ? 'text-[#D4AF37] fill-[#D4AF37]' : 'text-white/20'}`}
                      />
                    ))}
                    <span className="text-white/80 text-sm ml-1.5">
                      {hero.ratingValue}
                    </span>
                  </div>
                  <p className="text-white/50 text-xs sm:text-sm">
                    {hero.reviewLabel}
                  </p>
                </div>
              </div>
            </div>
          </div>

          {/* Right column - Stats cards (5 cols) */}
          <div
            className={`lg:col-span-5 hidden lg:block transition-all duration-1000 ${
              mounted ? 'opacity-100 translate-x-0' : 'opacity-0 translate-x-12'
            }`}
            style={{ transitionDelay: '400ms' }}
          >
            <div className="relative">
              {/* Decorative circles */}
              <div className="absolute inset-0 flex items-center justify-center">
                <div className="w-72 h-72 border border-[#D4AF37]/15 rounded-full animate-[spin_20s_linear_infinite]" />
                <div className="absolute w-96 h-96 border border-[#D4AF37]/8 rounded-full animate-[spin_30s_linear_infinite_reverse]" />
              </div>

              <div className="relative grid grid-cols-2 gap-4">
                {/* Stat card 1 */}
                <div className="group bg-white/5 backdrop-blur-md border border-white/10 rounded-2xl p-5 hover:bg-white/10 transition-all duration-500 hover:scale-[1.02] hover:-translate-y-1">
                  <div className="w-11 h-11 bg-[#D4AF37]/20 rounded-xl flex items-center justify-center mb-3 group-hover:scale-110 transition-transform duration-300">
                    <Award className="w-5 h-5 text-[#D4AF37]" />
                  </div>
                  <div className="text-3xl font-bold text-white mb-0.5">{hero.years}+</div>
                  <p className="text-white/50 text-sm">Années d'expérience</p>
                </div>

                {/* Stat card 2 */}
                <div className="group bg-white/5 backdrop-blur-md border border-white/10 rounded-2xl p-5 hover:bg-white/10 transition-all duration-500 hover:scale-[1.02] hover:-translate-y-1 mt-8">
                  <div className="w-11 h-11 bg-[#722F37]/30 rounded-xl flex items-center justify-center mb-3 group-hover:scale-110 transition-transform duration-300">
                    <Calendar className="w-5 h-5 text-[#FFF8F0]" />
                  </div>
                  <div className="text-3xl font-bold text-white mb-0.5">
                    {hero.eventValue}
                  </div>
                  <p className="text-white/50 text-sm">Événements réalisés</p>
                </div>

                {/* Stat card 3 */}
                <div className="group bg-white/5 backdrop-blur-md border border-white/10 rounded-2xl p-5 hover:bg-white/10 transition-all duration-500 hover:scale-[1.02] hover:-translate-y-1">
                  <div className="w-11 h-11 bg-[#556B2F]/30 rounded-xl flex items-center justify-center mb-3 group-hover:scale-110 transition-transform duration-300">
                    <Users className="w-5 h-5 text-[#8fad6a]" />
                  </div>
                  <div className="text-3xl font-bold text-white mb-0.5">
                    {hero.satisfactionValue}
                  </div>
                  <p className="text-white/50 text-sm">Clients satisfaits</p>
                </div>

                {/* Testimonial card */}
                <div className="group bg-gradient-to-br from-[#722F37] to-[#5a252c] rounded-2xl p-5 mt-8 shadow-xl shadow-[#722F37]/25 hover:shadow-[#722F37]/40 transition-all duration-500 hover:scale-[1.02] hover:-translate-y-1">
                  <div className="flex items-center gap-1 mb-2">
                    {[1, 2, 3, 4, 5].map((starValue) => (
                      <Star
                        key={starValue}
                        className={`w-3 h-3 ${starValue <= Math.round(hero.avgRating) ? 'text-[#D4AF37] fill-[#D4AF37]' : 'text-white/20'}`}
                      />
                    ))}
                  </div>
                  <p className="text-white/90 text-sm mb-3 leading-relaxed line-clamp-3">
                    "
                    {hero.testimonialText}
                    "
                  </p>
                  <div className="flex items-center gap-2">
                    <div className="w-7 h-7 rounded-full bg-[#D4AF37]/30 flex items-center justify-center text-white text-xs font-medium">
                      <Star className="w-3 h-3 fill-current" />
                    </div>
                    <span className="text-white/60 text-xs">{hero.reviewCount} avis vérifiés</span>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </div>

        {/* Mobile stats row */}
        <div
          className={`lg:hidden mt-10 sm:mt-12 grid grid-cols-3 gap-3 transition-all duration-700 ${
            mounted ? 'opacity-100 translate-y-0' : 'opacity-0 translate-y-6'
          }`}
          style={{ transitionDelay: '700ms' }}
        >
          {[
            { value: `${hero.years}+`, label: 'Années', icon: Award },
            { value: hero.eventValue, label: 'Événements', icon: Calendar },
            {
              value: hero.satisfactionValue,
              label: 'Satisfaits',
              icon: Users,
            },
          ].map((stat) => {
            const Icon = stat.icon;
            return (
              <div
                key={stat.label}
                className="text-center p-4 bg-white/5 backdrop-blur-sm rounded-xl border border-white/10"
              >
                <Icon className="w-5 h-5 text-[#D4AF37] mx-auto mb-2" />
                <div className="text-xl sm:text-2xl font-bold text-white">{stat.value}</div>
                <div className="text-white/50 text-xs mt-0.5">{stat.label}</div>
              </div>
            );
          })}
        </div>
      </div>

      {/* Scroll indicator */}
      <div
        className={`absolute bottom-6 sm:bottom-8 left-1/2 -translate-x-1/2 flex-col items-center gap-2 hidden sm:flex transition-all duration-700 ${
          mounted ? 'opacity-100 translate-y-0' : 'opacity-0 translate-y-4'
        }`}
        style={{ transitionDelay: '800ms' }}
      >
        <span className="text-white/60 text-[10px] tracking-[0.2em] uppercase">Scroll</span>
        <div className="w-5 h-8 border border-white/20 rounded-full flex justify-center">
          <div className="w-1 h-2.5 bg-[#D4AF37] rounded-full mt-1.5 animate-bounce" />
        </div>
      </div>
    </section>
  );
}
