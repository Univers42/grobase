// ============================================================
// Visitor Messages Seed Data — 10 contact-form submissions
// ============================================================
const now = new Date();

// Simple date factory: N days ago at given hour
const ago = (days, hour = 10) => {
  const d = new Date(now);
  d.setDate(d.getDate() - days);
  d.setHours(hour, 0, 0, 0);
  return d;
};

module.exports = [
  {
    visitor_name: 'Claire Dupont',
    email: 'claire.dupont@example.com',
    subject: 'Birthday party for my daughter',
    message:
      "Hello! My daughter turns 8 next month and she's obsessed with the penguins. Do you offer private birthday party packages near the Arctic exhibit? We'd be a group of 12 children and 6 adults. Thank you!",
    status: 'replied',
    reply:
      `Dear Claire, we would love to host your daughter's birthday! Our "Arctic Party" package includes 2 hours in the penguin pavilion, a keeper talk, and a birthday cake. I'll email you the full details shortly. — Sophie`,
    replied_at: ago(2, 14),
    created_at: ago(5, 9),
    updated_at: ago(2, 14),
  },
  {
    visitor_name: 'Thomas Wagner',
    email: 'thomas.w@example.com',
    subject: 'Accessibility question',
    message:
      "Hi, my mother uses a wheelchair. Are all the outdoor paths accessible? Is the Rainforest Dome wheelchair-friendly? We're planning to visit this Saturday.",
    status: 'replied',
    reply:
      'Hello Thomas, all main paths are fully wheelchair-accessible including the Rainforest Dome (ramp entrance on the east side). Wheelchairs are also available for free at reception. See you Saturday! — Lucas',
    replied_at: ago(1, 11),
    created_at: ago(3, 16),
    updated_at: ago(1, 11),
  },
  {
    visitor_name: 'Amélie Martin',
    email: 'amelie.martin@example.com',
    subject: 'Lost teddy bear!',
    message:
      "My son left his stuffed lion toy somewhere near the savannah viewing deck yesterday afternoon. It's brown with a red bow. He's very upset — any chance your team found it?",
    status: 'read',
    created_at: ago(1, 8),
    updated_at: ago(0, 9),
  },
  {
    visitor_name: 'Jake Peterson',
    email: 'jake.peterson@example.com',
    subject: 'Photography permit',
    message:
      "I'm a freelance wildlife photographer and I'd love to do a professional shoot at the zoo for my portfolio. Do you offer photography permits or special early-morning access? I'd be happy to provide copies of all images to your marketing team.",
    status: 'unread',
    created_at: ago(0, 7),
    updated_at: ago(0, 7),
  },
  {
    visitor_name: 'Sofia Rossi',
    email: 'sofia.rossi@example.com',
    subject: 'School group visit — 45 students',
    message:
      "I'm a primary school teacher and we'd like to organise an educational visit for 45 students (ages 9-10) in October. Do you have a guided programme with worksheets? What's the group rate?",
    status: 'replied',
    reply:
      'Dear Sofia, our "Classroom in the Wild" programme is perfect for your group! It includes a 2-hour guided tour, species worksheets aligned with the national curriculum, and a picnic area. Group rate is €8.50 per student, teachers free. Shall I send you a booking form? — Sophie',
    replied_at: ago(4, 10),
    created_at: ago(7, 11),
    updated_at: ago(4, 10),
  },
  {
    visitor_name: 'Omar Benali',
    email: 'omar.benali@example.com',
    subject: 'Volunteer programme',
    message:
      "I'm a biology student at the university and I'm looking for a volunteer or internship position at the zoo for the summer. I have experience with reptile husbandry from my personal collection. Do you accept volunteer applications?",
    status: 'read',
    created_at: ago(2, 15),
    updated_at: ago(1, 9),
  },
  {
    visitor_name: 'Hannah Kim',
    email: 'hannah.kim@example.com',
    subject: 'Vegan food options?',
    message:
      "We're a family of four and we're all vegan. What food options are available at the on-site cafe? Last time we visited (2 years ago) there was almost nothing plant-based. Hope it's improved!",
    status: 'replied',
    reply:
      "Hi Hannah! Great news — our café was fully renovated last year and now offers a dedicated plant-based menu including a vegan burger, falafel wrap, acai bowl, and oat-milk lattes. We can't wait to welcome you back! — Lucas",
    replied_at: ago(6, 16),
    created_at: ago(8, 12),
    updated_at: ago(6, 16),
  },
  {
    visitor_name: 'Marcel Fontaine',
    email: 'marcel.fontaine@example.com',
    subject: 'Complaint — rude staff at ticket booth',
    message:
      "I visited on Sunday and the person at the main ticket booth was incredibly rude when I asked about the senior discount. They rolled their eyes and barely explained the pricing. This is unacceptable for a €18.90 entry fee. I've been visiting this zoo for 30 years.",
    status: 'unread',
    created_at: ago(0, 14),
    updated_at: ago(0, 14),
  },
  {
    visitor_name: 'Elena Vasquez',
    email: 'elena.vasquez@example.com',
    subject: 'Adopting an animal symbolically',
    message:
      "I saw on your website that you have an animal adoption programme. I'd love to symbolically adopt Kibo the lion for my boyfriend's birthday. What are the different tiers and what's included?",
    status: 'replied',
    reply:
      "Hello Elena, what a wonderful gift idea! Our adoption tiers are: Bronze (€30 — certificate + photo), Silver (€60 — certificate, photo, plush toy), Gold (€120 — all of Silver plus a private keeper encounter). I'll attach the adoption form to a follow-up email. — Sophie",
    replied_at: ago(3, 17),
    created_at: ago(5, 20),
    updated_at: ago(3, 17),
  },
  {
    visitor_name: "Liam O'Brien",
    email: 'liam.obrien@example.com',
    subject: 'Parking situation',
    message:
      "Is there a bigger parking lot planned? Last two visits we had to park on the street 500m away. With two small kids and a stroller it's a nightmare. The zoo itself is wonderful though!",
    status: 'archived',
    created_at: ago(30, 10),
    updated_at: ago(25, 8),
  },
];
