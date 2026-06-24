import { useEffect } from 'react';
import { Link } from 'react-router-dom';
import { motion } from 'framer-motion';
import { ArrowRight, Ticket, MapPin, Clock, Star } from 'lucide-react';
import { useAnimalStore } from '@/stores/animalStore';
import ZoneBadge, { ZONE_CONFIG } from '@/components/ui/ZoneBadge';
import useBaasCollection from '@/hooks/useBaasCollection';

// ── Hero Section ──────────────────────────────────────────────
function Hero() {
  return (
    <section className="relative flex min-h-[90vh] items-center justify-center overflow-hidden bg-forest pt-16">
      {/* Background pattern */}
      <div className="absolute inset-0 bg-hero-gradient" />
      <div
        className="absolute inset-0 opacity-10"
        style={{
          backgroundImage:
            "url(\"data:image/svg+xml,%3Csvg width='60' height='60' viewBox='0 0 60 60' xmlns='http://www.w3.org/2000/svg'%3E%3Cg fill='none' fill-rule='evenodd'%3E%3Cg fill='%23ffffff' fill-opacity='0.4'%3E%3Cpath d='M36 34v-4h-2v4h-4v2h4v4h2v-4h4v-2h-4zm0-30V0h-2v4h-4v2h4v4h2V6h4V4h-4zM6 34v-4H4v4H0v2h4v4h2v-4h4v-2H6zM6 4V0H4v4H0v2h4v4h2V6h4V4H6z'/%3E%3C/g%3E%3C/g%3E%3C/svg%3E\")",
        }}
      />

      <div className="relative z-10 mx-auto max-w-5xl px-4 text-center">
        <motion.p
          initial={{ opacity: 0, y: 20 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ delay: 0.1 }}
          className="mb-4 font-body text-sm font-medium uppercase tracking-[0.2em] text-amber"
        >
          Wildlife Sanctuary & Conservation Park
        </motion.p>

        <motion.h1
          initial={{ opacity: 0, y: 30 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ delay: 0.2 }}
          className="font-display text-6xl font-bold leading-tight text-ivory md:text-8xl"
        >
          Savanna Park
          <span className="block text-amber">Zoo</span>
        </motion.h1>

        <motion.p
          initial={{ opacity: 0, y: 20 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ delay: 0.4 }}
          className="mx-auto mt-6 max-w-2xl text-lg leading-relaxed text-ivory/70"
        >
          Step into a world where African elephants roam vast savannahs, polar
          bears glide through arctic waters, and jaguars prowl lush rainforests.
          Over 200 species, 7 immersive zones, 1 unforgettable adventure.
        </motion.p>

        <motion.div
          initial={{ opacity: 0, y: 20 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ delay: 0.6 }}
          className="mt-10 flex flex-wrap items-center justify-center gap-4"
        >
          <Link to="/tickets" className="btn-amber text-base">
            <Ticket className="h-5 w-5" />
            Buy Tickets
          </Link>
          <Link to="/animals" className="btn-secondary !border-ivory/30 !text-ivory hover:!bg-ivory hover:!text-forest text-base">
            Explore Animals
            <ArrowRight className="h-4 w-4" />
          </Link>
        </motion.div>

        {/* Quick info pills */}
        <motion.div
          initial={{ opacity: 0 }}
          animate={{ opacity: 1 }}
          transition={{ delay: 0.8 }}
          className="mt-12 flex flex-wrap justify-center gap-6 text-sm text-ivory/60"
        >
          <span className="flex items-center gap-1.5"><Clock className="h-4 w-4" /> Open 9:00 – 18:00</span>
          <span className="flex items-center gap-1.5"><MapPin className="h-4 w-4" /> Paris, France</span>
          <span className="flex items-center gap-1.5"><Star className="h-4 w-4" /> 4.8★ (2,400+ reviews)</span>
        </motion.div>
      </div>

      {/* Scroll indicator */}
      <div className="absolute bottom-8 left-1/2 -translate-x-1/2">
        <div className="h-10 w-6 rounded-full border-2 border-ivory/30 p-1">
          <motion.div
            animate={{ y: [0, 12, 0] }}
            transition={{ repeat: Infinity, duration: 1.5 }}
            className="h-2 w-2 rounded-full bg-amber"
          />
        </div>
      </div>
    </section>
  );
}

// ── Featured Animals ──────────────────────────────────────────
function FeaturedAnimals() {
  const { featured, fetchFeatured } = useAnimalStore();

  useEffect(() => {
    fetchFeatured();
  }, [fetchFeatured]);

  if (!featured.length) return null;

  return (
    <section className="bg-ivory py-20">
      <div className="mx-auto max-w-7xl px-4 sm:px-6 lg:px-8">
        <div className="text-center">
          <h2 className="section-heading">Meet Our Stars</h2>
          <p className="section-subtitle mx-auto">
            Get to know the incredible animals that call Savanna Park home.
          </p>
        </div>

        <div className="mt-12 grid gap-6 sm:grid-cols-2 lg:grid-cols-3">
          {featured.slice(0, 6).map((animal, i) => (
            <motion.div
              key={animal.id}
              initial={{ opacity: 0, y: 30 }}
              whileInView={{ opacity: 1, y: 0 }}
              viewport={{ once: true }}
              transition={{ delay: i * 0.1 }}
            >
              <Link to={`/animals/${animal.id}`} className="card group block">
                {/* Image placeholder */}
                <div className="relative aspect-[4/3] overflow-hidden bg-sand">
                  <div className="absolute inset-0 flex items-center justify-center bg-forest/10">
                    <span className="text-6xl">{getZoneEmoji(animal.zone)}</span>
                  </div>
                  <div className="absolute inset-0 bg-card-gradient opacity-0 transition-opacity group-hover:opacity-100" />
                </div>

                <div className="p-5">
                  <div className="flex items-start justify-between">
                    <div>
                      <h3 className="font-display text-xl font-bold text-forest">{animal.name}</h3>
                      <p className="text-sm italic text-charcoal/50">{animal.species}</p>
                    </div>
                    <ZoneBadge zone={animal.zone} />
                  </div>
                  <p className="mt-3 line-clamp-2 text-sm text-charcoal/70">
                    {animal.description}
                  </p>
                </div>
              </Link>
            </motion.div>
          ))}
        </div>

        <div className="mt-10 text-center">
          <Link to="/animals" className="btn-secondary">
            View All Animals <ArrowRight className="h-4 w-4" />
          </Link>
        </div>
      </div>
    </section>
  );
}

// ── Zones Grid ────────────────────────────────────────────────
function ZonesSection() {
  const zones = Object.entries(ZONE_CONFIG);

  return (
    <section className="bg-sand-light py-20">
      <div className="mx-auto max-w-7xl px-4 sm:px-6 lg:px-8">
        <div className="text-center">
          <h2 className="section-heading">7 Immersive Zones</h2>
          <p className="section-subtitle mx-auto">
            Each zone is a meticulously crafted ecosystem — from scorching
            savannahs to the depths of the ocean.
          </p>
        </div>

        <div className="mt-12 grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
          {zones.map(([key, cfg], i) => (
            <motion.div
              key={key}
              initial={{ opacity: 0, scale: 0.95 }}
              whileInView={{ opacity: 1, scale: 1 }}
              viewport={{ once: true }}
              transition={{ delay: i * 0.05 }}
            >
              <Link
                to={`/animals?zone=${key}`}
                className="card group flex flex-col items-center p-6 text-center"
              >
                <span className="text-5xl transition-transform duration-300 group-hover:scale-110">
                  {cfg.emoji}
                </span>
                <h3 className="mt-3 font-display text-lg font-bold text-forest">
                  {cfg.label}
                </h3>
              </Link>
            </motion.div>
          ))}
        </div>
      </div>
    </section>
  );
}

// ── Upcoming Events ───────────────────────────────────────────
function UpcomingEvents() {
  const { data: events } = useBaasCollection('events', {
    filters: { is_active: true },
    order: 'start_at.asc',
    limit: 3,
  });

  if (!events?.length) return null;

  return (
    <section className="bg-ivory py-20">
      <div className="mx-auto max-w-7xl px-4 sm:px-6 lg:px-8">
        <div className="text-center">
          <h2 className="section-heading">Upcoming Events</h2>
          <p className="section-subtitle mx-auto">
            Feeding shows, night safaris, VIP experiences, and more.
          </p>
        </div>

        <div className="mt-12 grid gap-6 md:grid-cols-3">
          {events.map((evt, i) => (
            <motion.div
              key={evt.id}
              initial={{ opacity: 0, y: 20 }}
              whileInView={{ opacity: 1, y: 0 }}
              viewport={{ once: true }}
              transition={{ delay: i * 0.1 }}
              className="card p-6"
            >
              <div className="flex items-center justify-between">
                <ZoneBadge zone={evt.zone} />
                {evt.is_free ? (
                  <span className="text-xs font-bold uppercase text-green-600">Free</span>
                ) : (
                  <span className="text-sm font-bold text-amber">€{evt.price_eur}</span>
                )}
              </div>
              <h3 className="mt-3 font-display text-lg font-bold text-forest">{evt.title}</h3>
              <p className="mt-2 line-clamp-2 text-sm text-charcoal/60">{evt.description}</p>
              <div className="mt-4 flex items-center justify-between text-xs text-charcoal/50">
                <span>{new Date(evt.start_at).toLocaleDateString('en-GB', { day: 'numeric', month: 'short' })}</span>
                <span>{evt.registrations}/{evt.capacity} spots</span>
              </div>
              {evt.is_full && (
                <span className="mt-2 inline-block rounded-full bg-red-100 px-2 py-0.5 text-xs font-semibold text-red-700">
                  Sold Out
                </span>
              )}
            </motion.div>
          ))}
        </div>

        <div className="mt-10 text-center">
          <Link to="/events" className="btn-secondary">
            All Events <ArrowRight className="h-4 w-4" />
          </Link>
        </div>
      </div>
    </section>
  );
}

// ── CTA Banner ────────────────────────────────────────────────
function CtaBanner() {
  return (
    <section className="bg-forest py-20">
      <div className="mx-auto max-w-3xl px-4 text-center">
        <h2 className="font-display text-4xl font-bold text-ivory md:text-5xl">
          Plan Your Visit Today
        </h2>
        <p className="mt-4 text-lg text-ivory/70">
          Tickets start at just €14.90. Children under 3 enter free.
          Your visit directly funds conservation programmes worldwide.
        </p>
        <div className="mt-8 flex flex-wrap justify-center gap-4">
          <Link to="/tickets" className="btn-amber text-base">
            <Ticket className="h-5 w-5" /> Get Tickets
          </Link>
          <Link to="/contact" className="btn-secondary !border-ivory/30 !text-ivory hover:!bg-ivory hover:!text-forest text-base">
            Contact Us
          </Link>
        </div>
      </div>
    </section>
  );
}

// ── Helpers ───────────────────────────────────────────────────
function getZoneEmoji(zone) {
  return ZONE_CONFIG[zone]?.emoji || '🌍';
}

// ── Page ──────────────────────────────────────────────────────
export default function Home() {
  return (
    <>
      <Hero />
      <FeaturedAnimals />
      <ZonesSection />
      <UpcomingEvents />
      <CtaBanner />
    </>
  );
}
