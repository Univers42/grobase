// ============================================================
// Events Seed Data — 6 upcoming zoo events across all types
// ============================================================
const { ObjectId } = require('mongodb');
const now = new Date();

// Helper: date N days from now at given hour
const future = (days, hour, min = 0) => {
  const d = new Date(now);
  d.setDate(d.getDate() + days);
  d.setHours(hour, min, 0, 0);
  return d;
};

module.exports = [
  {
    _id: new ObjectId('66b000000000000000000001'),
    title: "Lion's Lunch — Live Feeding Show",
    type: 'feeding_show',
    description:
      'Watch Kibo devour 6 kg of raw beef while our keeper Marcus explains the hunting strategies of African lions. Get close-up views from the elevated feeding platform.',
    start_at: future(3, 11, 0),
    end_at: future(3, 11, 45),
    zone: 'savannah',
    capacity: 80,
    registrations: 62,
    price_eur: 0,
    is_free: true,
    animals: [new ObjectId('65a000000000000000000001')],
    cover_photo: '/storage/events/lion_feeding.jpg',
    host: 'Marcus Osei',
    is_active: true,
    is_full: false,
    created_at: now,
    updated_at: now,
  },
  {
    _id: new ObjectId('66b000000000000000000002'),
    title: 'Midnight Safari — After-Dark Experience',
    type: 'night_safari',
    description:
      'Experience the zoo after sunset as nocturnal animals awaken. LED-lit trails wind past the savannah and rainforest zones. Includes night-vision binoculars and a hot-chocolate station.',
    start_at: future(7, 20, 30),
    end_at: future(7, 23, 0),
    zone: 'savannah',
    capacity: 40,
    registrations: 38,
    price_eur: 39.9,
    is_free: false,
    animals: [
      new ObjectId('65a000000000000000000001'),
      new ObjectId('65a000000000000000000005'),
    ],
    cover_photo: '/storage/events/night_safari.jpg',
    host: 'Sophie Laurent',
    is_active: true,
    is_full: false,
    created_at: now,
    updated_at: now,
  },
  {
    _id: new ObjectId('66b000000000000000000003'),
    title: 'Junior Zookeeper for a Day',
    type: 'kids_workshop',
    description:
      'Children aged 6-12 join our team for a full-day immersion. They will help prepare meals in the Petting Zone, learn about animal enrichment, and receive a certificate and a plush toy.',
    start_at: future(10, 9, 0),
    end_at: future(10, 16, 0),
    zone: 'petting',
    capacity: 20,
    registrations: 20,
    price_eur: 29.9,
    is_free: false,
    animals: [new ObjectId('65a00000000000000000000b')],
    cover_photo: '/storage/events/junior_zookeeper.jpg',
    host: 'Elena Moreau',
    is_active: true,
    is_full: true,
    created_at: now,
    updated_at: now,
  },
  {
    _id: new ObjectId('66b000000000000000000004'),
    title: 'Behind the Ice — Polar Bear Guided Tour',
    type: 'guided_tour',
    description:
      'Step behind the scenes of our Arctic Tundra exhibit for a 90-minute guided tour. Meet Glacier up close from the keeper tunnel and learn about polar conservation.',
    start_at: future(5, 14, 0),
    end_at: future(5, 15, 30),
    zone: 'arctic',
    capacity: 25,
    registrations: 11,
    price_eur: 24.9,
    is_free: false,
    animals: [
      new ObjectId('65a000000000000000000004'),
      new ObjectId('65a00000000000000000000a'),
    ],
    cover_photo: '/storage/events/polar_tour.jpg',
    host: 'Marcus Osei',
    is_active: true,
    is_full: false,
    created_at: now,
    updated_at: now,
  },
  {
    _id: new ObjectId('66b000000000000000000005'),
    title: 'Sunset VIP — Champagne & Conservation',
    type: 'vip_experience',
    description:
      'An exclusive evening for up to 12 guests — private access to the Savannah overlook terrace with champagne, canapés, and a personal guide. Proceeds fund the African elephant conservation fund.',
    start_at: future(14, 18, 30),
    end_at: future(14, 21, 0),
    zone: 'savannah',
    capacity: 12,
    registrations: 5,
    price_eur: 149.9,
    is_free: false,
    animals: [
      new ObjectId('65a000000000000000000001'),
      new ObjectId('65a000000000000000000002'),
      new ObjectId('65a00000000000000000000c'),
    ],
    cover_photo: '/storage/events/vip_sunset.jpg',
    host: 'Sophie Laurent',
    is_active: true,
    is_full: false,
    created_at: now,
    updated_at: now,
  },
  {
    _id: new ObjectId('66b000000000000000000006'),
    title: 'Ocean Depths — Aquarium Feeding Dive',
    type: 'feeding_show',
    description:
      'Our aquarium keeper Elena dives into the main reef tank to hand-feed the sea turtles and stingrays while narrating the experience via an underwater microphone. A mesmerising show for all ages.',
    start_at: future(2, 10, 30),
    end_at: future(2, 11, 15),
    zone: 'aquarium',
    capacity: 60,
    registrations: 45,
    price_eur: 0,
    is_free: true,
    animals: [
      new ObjectId('65a000000000000000000003'),
      new ObjectId('65a000000000000000000009'),
    ],
    cover_photo: '/storage/events/aquarium_dive.jpg',
    host: 'Elena Moreau',
    is_active: true,
    is_full: false,
    created_at: now,
    updated_at: now,
  },
];
