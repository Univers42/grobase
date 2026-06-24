import { motion } from 'framer-motion';
import { Calendar, Clock, MapPin, Users } from 'lucide-react';
import useBaasCollection from '@/hooks/useBaasCollection';
import ZoneBadge from '@/components/ui/ZoneBadge';

const TYPE_LABELS = {
  feeding_show:  { label: 'Feeding Show',  emoji: '🍖' },
  guided_tour:   { label: 'Guided Tour',   emoji: '🗺️' },
  kids_workshop: { label: "Kids' Workshop",emoji: '🧒' },
  night_safari:  { label: 'Night Safari',  emoji: '🌙' },
  vip_experience:{ label: 'VIP Experience', emoji: '🥂' },
};

function fmtDate(iso) {
  return new Date(iso).toLocaleDateString('en-GB', { weekday: 'short', day: 'numeric', month: 'short' });
}
function fmtTime(iso) {
  return new Date(iso).toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' });
}

export default function Events() {
  const { data: events, loading } = useBaasCollection('events', {
    filters: { is_active: true },
    order: 'start_at.asc',
  });

  return (
    <div className="pt-16">
      {/* Header */}
      <section className="bg-forest px-4 py-16 text-center">
        <motion.h1
          initial={{ opacity: 0, y: 20 }}
          animate={{ opacity: 1, y: 0 }}
          className="font-display text-5xl font-bold text-ivory md:text-6xl"
        >
          Events & Experiences
        </motion.h1>
        <p className="mx-auto mt-3 max-w-xl text-ivory/60">
          From live feeding shows to exclusive night safaris — there's always
          something extraordinary happening at Savanna Park.
        </p>
      </section>

      <div className="mx-auto max-w-5xl px-4 py-12 sm:px-6">
        {loading && <p className="text-center text-charcoal/50">Loading events…</p>}

        <div className="space-y-6">
          {events?.map((evt, i) => {
            const typeInfo = TYPE_LABELS[evt.type] || { label: evt.type, emoji: '📅' };
            const spotsLeft = evt.capacity - (evt.registrations || 0);

            return (
              <motion.div
                key={evt.id}
                initial={{ opacity: 0, y: 20 }}
                animate={{ opacity: 1, y: 0 }}
                transition={{ delay: Math.min(i * 0.08, 0.5) }}
                className="card overflow-hidden"
              >
                <div className="flex flex-col md:flex-row">
                  {/* Date sidebar */}
                  <div className="flex flex-shrink-0 flex-col items-center justify-center bg-forest p-6 text-ivory md:w-36">
                    <span className="text-3xl">{typeInfo.emoji}</span>
                    <span className="mt-2 text-xs font-medium uppercase tracking-wider text-ivory/60">
                      {typeInfo.label}
                    </span>
                    <span className="mt-1 font-display text-lg font-bold">
                      {fmtDate(evt.start_at)}
                    </span>
                  </div>

                  {/* Content */}
                  <div className="flex-1 p-6">
                    <div className="flex flex-wrap items-start justify-between gap-3">
                      <div>
                        <h3 className="font-display text-xl font-bold text-forest">{evt.title}</h3>
                        <div className="mt-1 flex flex-wrap items-center gap-3 text-xs text-charcoal/50">
                          <span className="flex items-center gap-1">
                            <Clock className="h-3.5 w-3.5" />
                            {fmtTime(evt.start_at)} – {fmtTime(evt.end_at)}
                          </span>
                          <ZoneBadge zone={evt.zone} />
                          {evt.host && (
                            <span className="flex items-center gap-1">
                              <Users className="h-3.5 w-3.5" /> {evt.host}
                            </span>
                          )}
                        </div>
                      </div>

                      {/* Price */}
                      <div className="text-right">
                        {evt.is_free ? (
                          <span className="rounded-full bg-green-100 px-3 py-1 text-sm font-bold text-green-700">
                            Free
                          </span>
                        ) : (
                          <span className="font-display text-2xl font-bold text-amber">
                            €{evt.price_eur}
                          </span>
                        )}
                      </div>
                    </div>

                    <p className="mt-3 text-sm leading-relaxed text-charcoal/60">
                      {evt.description}
                    </p>

                    {/* Capacity bar */}
                    <div className="mt-4">
                      <div className="flex items-center justify-between text-xs">
                        <span className="text-charcoal/50">
                          {evt.registrations || 0} / {evt.capacity} registered
                        </span>
                        {evt.is_full ? (
                          <span className="font-semibold text-red-600">Sold Out</span>
                        ) : (
                          <span className="text-green-600">{spotsLeft} spots left</span>
                        )}
                      </div>
                      <div className="mt-1.5 h-2 overflow-hidden rounded-full bg-sand">
                        <div
                          className={`h-full rounded-full transition-all duration-500 ${
                            evt.is_full ? 'bg-red-400' : 'bg-forest'
                          }`}
                          style={{
                            width: `${Math.min(((evt.registrations || 0) / evt.capacity) * 100, 100)}%`,
                          }}
                        />
                      </div>
                    </div>
                  </div>
                </div>
              </motion.div>
            );
          })}
        </div>

        {!loading && (!events || events.length === 0) && (
          <div className="py-20 text-center">
            <Calendar className="mx-auto h-12 w-12 text-charcoal/20" />
            <p className="mt-4 text-charcoal/50">No upcoming events right now. Check back soon!</p>
          </div>
        )}
      </div>
    </div>
  );
}
