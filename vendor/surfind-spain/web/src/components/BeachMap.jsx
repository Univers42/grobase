import { useEffect, useRef } from 'react';
import L from 'leaflet';
import { DIFFICULTY_LABELS } from '@/components/ui/DifficultyBadge';

const SPAIN_CENTER = [40.25, -3.7];
const TILE_URL = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
const ATTRIBUTION =
  '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors';

function esc(value) {
  return String(value ?? '')
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#039;');
}

function popupHtml(beach) {
  const diff = DIFFICULTY_LABELS[beach.difficulty] || '';
  return `<article class="surfind-popup">
      <h3>${esc(beach.name)}</h3>
      <p>${esc(beach.location?.name || '')}${diff ? ` · ${esc(diff)}` : ''}</p>
      <a href="/playas/${esc(beach.slug)}" data-beach-link="${esc(beach.slug)}">Ver ficha</a>
    </article>`;
}

/**
 * Leaflet map of beach markers. Bundled (npm 'leaflet'), no CDN — CSP 'self'.
 * @param beaches  array with {name,slug,latitude,longitude,difficulty,location}
 * @param focusSlug optional slug to center+open
 * @param onSelect  optional callback(slug) when a popup "Ver ficha" link is clicked (SPA nav)
 */
export default function BeachMap({ beaches, focusSlug = null, onSelect, className = 'h-[28rem]' }) {
  const ref = useRef(null);
  const mapRef = useRef(null);

  useEffect(() => {
    const el = ref.current;
    if (!el || mapRef.current) return;

    const map = L.map(el, { scrollWheelZoom: true, zoomControl: false });
    mapRef.current = map;
    L.control.zoom({ position: 'bottomright' }).addTo(map);
    L.tileLayer(TILE_URL, { maxZoom: 19, attribution: ATTRIBUTION }).addTo(map);

    const icon = L.divIcon({
      className: 'surfind-marker',
      html: '<span style="display:block;width:18px;height:18px;border-radius:50% 50% 50% 0;background:#002833;transform:rotate(-45deg);border:2px solid #fff;box-shadow:0 4px 10px rgba(17,72,87,.4)"></span>',
      iconSize: [18, 18],
      iconAnchor: [9, 18],
      popupAnchor: [0, -16],
    });

    const markers = new Map();
    (beaches || []).forEach((b) => {
      if (b.latitude == null || b.longitude == null) return;
      const m = L.marker([Number(b.latitude), Number(b.longitude)], { icon })
        .addTo(map)
        .bindPopup(popupHtml(b), { maxWidth: 240, minWidth: 200 });
      markers.set(b.slug, m);
    });

    const focus = focusSlug && markers.get(focusSlug);
    if (focus) {
      map.setView(focus.getLatLng(), 13, { animate: false });
      focus.openPopup();
    } else {
      map.setView(SPAIN_CENTER, 6);
    }

    map.on('popupopen', (e) => {
      const link = e.popup.getElement()?.querySelector('[data-beach-link]');
      if (link && onSelect) {
        link.addEventListener('click', (ev) => {
          ev.preventDefault();
          onSelect(link.getAttribute('data-beach-link'));
        });
      }
    });

    setTimeout(() => map.invalidateSize(), 80);
    return () => { map.remove(); mapRef.current = null; };
  }, [beaches, focusSlug, onSelect]);

  return <div ref={ref} className={`w-full overflow-hidden rounded-[1.85rem] bg-ocean-pale ${className}`} />;
}
