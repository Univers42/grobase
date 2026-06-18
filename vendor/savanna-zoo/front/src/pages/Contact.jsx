import { useState } from 'react';
import { motion } from 'framer-motion';
import { Send, MapPin, Phone, Mail, Clock, CheckCircle2 } from 'lucide-react';
import baas from '@/baas/client';

export default function Contact() {
  const [form, setForm] = useState({ name: '', email: '', subject: '', message: '' });
  const [sending, setSending] = useState(false);
  const [sent, setSent] = useState(false);

  const update = (field) => (e) => setForm((f) => ({ ...f, [field]: e.target.value }));

  const handleSubmit = async (e) => {
    e.preventDefault();
    setSending(true);
    try {
      await baas.collection('visitor_messages').insert({
        visitor_name: form.name,
        email: form.email,
        subject: form.subject,
        message: form.message,
        status: 'unread',
        created_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
      });
      setSent(true);
      setForm({ name: '', email: '', subject: '', message: '' });
    } catch (err) {
      alert('Failed to send: ' + err.message);
    } finally {
      setSending(false);
    }
  };

  return (
    <div className="pt-16">
      {/* Header */}
      <section className="bg-forest px-4 py-16 text-center">
        <motion.h1
          initial={{ opacity: 0, y: 20 }}
          animate={{ opacity: 1, y: 0 }}
          className="font-display text-5xl font-bold text-ivory md:text-6xl"
        >
          Contact Us
        </motion.h1>
        <p className="mx-auto mt-3 max-w-xl text-ivory/60">
          Questions, feedback, or just want to say hello? We'd love to hear from you.
        </p>
      </section>

      <div className="mx-auto max-w-5xl px-4 py-12 sm:px-6">
        <div className="grid gap-12 lg:grid-cols-5">
          {/* Contact form */}
          <motion.div
            initial={{ opacity: 0, y: 20 }}
            animate={{ opacity: 1, y: 0 }}
            className="lg:col-span-3"
          >
            {sent ? (
              <div className="card flex flex-col items-center p-12 text-center">
                <CheckCircle2 className="h-16 w-16 text-forest" />
                <h2 className="mt-4 font-display text-2xl font-bold text-forest">
                  Message Sent!
                </h2>
                <p className="mt-2 text-charcoal/60">
                  Thank you for reaching out. Our team will get back to you within 24 hours.
                </p>
                <button
                  onClick={() => setSent(false)}
                  className="btn-secondary mt-6"
                >
                  Send Another Message
                </button>
              </div>
            ) : (
              <form onSubmit={handleSubmit} className="card p-8 space-y-5">
                <h2 className="font-display text-2xl font-bold text-forest">Send a Message</h2>

                <div className="grid gap-5 sm:grid-cols-2">
                  <div>
                    <label className="mb-1 block text-sm font-medium text-charcoal/60">Name *</label>
                    <input
                      type="text"
                      required
                      value={form.name}
                      onChange={update('name')}
                      placeholder="Your full name"
                      className="w-full rounded-xl border border-sand bg-ivory px-4 py-2.5 text-sm outline-none focus:border-forest focus:ring-2 focus:ring-forest/20"
                    />
                  </div>
                  <div>
                    <label className="mb-1 block text-sm font-medium text-charcoal/60">Email *</label>
                    <input
                      type="email"
                      required
                      value={form.email}
                      onChange={update('email')}
                      placeholder="you@example.com"
                      className="w-full rounded-xl border border-sand bg-ivory px-4 py-2.5 text-sm outline-none focus:border-forest focus:ring-2 focus:ring-forest/20"
                    />
                  </div>
                </div>

                <div>
                  <label className="mb-1 block text-sm font-medium text-charcoal/60">Subject *</label>
                  <input
                    type="text"
                    required
                    value={form.subject}
                    onChange={update('subject')}
                    placeholder="What is this about?"
                    className="w-full rounded-xl border border-sand bg-ivory px-4 py-2.5 text-sm outline-none focus:border-forest focus:ring-2 focus:ring-forest/20"
                  />
                </div>

                <div>
                  <label className="mb-1 block text-sm font-medium text-charcoal/60">Message *</label>
                  <textarea
                    required
                    rows={5}
                    value={form.message}
                    onChange={update('message')}
                    placeholder="Tell us more…"
                    className="w-full resize-none rounded-xl border border-sand bg-ivory px-4 py-3 text-sm outline-none focus:border-forest focus:ring-2 focus:ring-forest/20"
                  />
                </div>

                <button
                  type="submit"
                  disabled={sending}
                  className="btn-primary w-full sm:w-auto disabled:opacity-50"
                >
                  <Send className="h-4 w-4" />
                  {sending ? 'Sending…' : 'Send Message'}
                </button>
              </form>
            )}
          </motion.div>

          {/* Sidebar info */}
          <motion.aside
            initial={{ opacity: 0, x: 20 }}
            animate={{ opacity: 1, x: 0 }}
            transition={{ delay: 0.2 }}
            className="lg:col-span-2 space-y-6"
          >
            <div className="card p-6 space-y-5">
              <h3 className="font-display text-lg font-bold text-forest">Visit Us</h3>

              <div className="flex items-start gap-3 text-sm">
                <MapPin className="mt-0.5 h-5 w-5 flex-shrink-0 text-amber" />
                <div>
                  <p className="font-medium">42 Safari Road</p>
                  <p className="text-charcoal/50">75001 Paris, France</p>
                </div>
              </div>

              <div className="flex items-start gap-3 text-sm">
                <Phone className="mt-0.5 h-5 w-5 flex-shrink-0 text-amber" />
                <div>
                  <p className="font-medium">+33 1 42 00 00 00</p>
                  <p className="text-charcoal/50">Mon–Sun, 9:00–18:00</p>
                </div>
              </div>

              <div className="flex items-start gap-3 text-sm">
                <Mail className="mt-0.5 h-5 w-5 flex-shrink-0 text-amber" />
                <div>
                  <p className="font-medium">hello@savanna-zoo.com</p>
                  <p className="text-charcoal/50">We reply within 24 hours</p>
                </div>
              </div>
            </div>

            <div className="card p-6">
              <h3 className="font-display text-lg font-bold text-forest">Opening Hours</h3>
              <ul className="mt-3 space-y-2 text-sm">
                <li className="flex items-center gap-2">
                  <Clock className="h-4 w-4 text-amber" />
                  <span className="text-charcoal/60">Mon – Fri:</span>
                  <span className="ml-auto font-medium">9:00 – 18:00</span>
                </li>
                <li className="flex items-center gap-2">
                  <Clock className="h-4 w-4 text-amber" />
                  <span className="text-charcoal/60">Saturday:</span>
                  <span className="ml-auto font-medium">9:00 – 20:00</span>
                </li>
                <li className="flex items-center gap-2">
                  <Clock className="h-4 w-4 text-amber" />
                  <span className="text-charcoal/60">Sunday:</span>
                  <span className="ml-auto font-medium">10:00 – 18:00</span>
                </li>
              </ul>
              <p className="mt-3 text-xs text-amber font-medium">Last entry 1 hour before close</p>
            </div>
          </motion.aside>
        </div>
      </div>
    </div>
  );
}
