import { Link } from 'react-router-dom';
import { TreePine, Mail, Phone, MapPin } from 'lucide-react';

export default function Footer() {
  return (
    <footer className="bg-forest text-ivory/80">
      <div className="mx-auto max-w-7xl px-4 py-16 sm:px-6 lg:px-8">
        <div className="grid gap-12 md:grid-cols-4">
          {/* Brand */}
          <div className="md:col-span-1">
            <Link to="/" className="flex items-center gap-2 text-ivory">
              <TreePine className="h-7 w-7 text-amber" />
              <span className="font-display text-xl font-bold">Savanna Park</span>
            </Link>
            <p className="mt-4 text-sm leading-relaxed text-ivory/60">
              Where wildlife meets wonder. A world-class sanctuary dedicated to
              conservation, education, and unforgettable experiences.
            </p>
          </div>

          {/* Quick Links */}
          <div>
            <h4 className="mb-4 font-display text-lg font-semibold text-ivory">Visit</h4>
            <ul className="space-y-2 text-sm">
              <li><Link to="/animals" className="hover:text-amber transition-colors">Our Animals</Link></li>
              <li><Link to="/events"  className="hover:text-amber transition-colors">Events</Link></li>
              <li><Link to="/tickets" className="hover:text-amber transition-colors">Buy Tickets</Link></li>
              <li><Link to="/contact" className="hover:text-amber transition-colors">Contact Us</Link></li>
            </ul>
          </div>

          {/* Hours */}
          <div>
            <h4 className="mb-4 font-display text-lg font-semibold text-ivory">Hours</h4>
            <ul className="space-y-2 text-sm">
              <li>Mon – Fri: 9:00 – 18:00</li>
              <li>Saturday: 9:00 – 20:00</li>
              <li>Sunday: 10:00 – 18:00</li>
              <li className="text-amber font-medium">Last entry 1h before close</li>
            </ul>
          </div>

          {/* Contact */}
          <div>
            <h4 className="mb-4 font-display text-lg font-semibold text-ivory">Contact</h4>
            <ul className="space-y-3 text-sm">
              <li className="flex items-center gap-2">
                <MapPin className="h-4 w-4 text-amber flex-shrink-0" />
                42 Safari Road, 75001 Paris
              </li>
              <li className="flex items-center gap-2">
                <Phone className="h-4 w-4 text-amber flex-shrink-0" />
                +33 1 42 00 00 00
              </li>
              <li className="flex items-center gap-2">
                <Mail className="h-4 w-4 text-amber flex-shrink-0" />
                hello@savanna-zoo.com
              </li>
            </ul>
          </div>
        </div>

        {/* Bottom bar */}
        <div className="mt-12 flex flex-col items-center justify-between gap-4 border-t border-ivory/10 pt-8 sm:flex-row">
          <p className="text-xs text-ivory/40">
            © {new Date().getFullYear()} Savanna Park Zoo. All rights reserved.
          </p>
          <p className="text-xs text-ivory/40">
            Powered by <span className="text-amber font-medium">mini-baas</span>
          </p>
        </div>
      </div>
    </footer>
  );
}
