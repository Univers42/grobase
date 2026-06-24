import baas, { storage } from '@/baas/client';

// PostgREST embed: beach + its location + amenities (through the join table) + images.
// '*' carries the surf-intel + media columns (break_type … cover_image, rating_avg…).
const BEACH_SELECT =
  '*,location:locations(name,slug),amenities:amenity_beach(amenities(name,icon)),images:beach_images(path,external_url,is_cover,sort_order,alt_text)';

/** Flatten the amenity_beach→amenities embed into a plain [{name,icon}] list. */
export function beachAmenities(beach) {
  return (beach?.amenities || []).map((a) => a.amenities).filter(Boolean);
}

/** Resolve a beach cover URL: the cover_image column first, else its images embed. */
export function beachCover(beach) {
  if (beach?.cover_image) return beach.cover_image;
  const images = beach?.images || [];
  const cover = images.find((i) => i.is_cover) || images[0];
  if (!cover) return null;
  return cover.external_url || storage.getUrl(cover.path);
}

/** Gallery image URLs (non-cover, sorted) for the detail strip. */
export function beachGallery(beach) {
  return (beach?.images || [])
    .filter((i) => !i.is_cover)
    .sort((a, b) => (a.sort_order || 0) - (b.sort_order || 0))
    .map((i) => i.external_url || storage.getUrl(i.path))
    .filter(Boolean);
}

/** Published beaches with full embeds, newest first. */
export function publishedBeaches() {
  return baas
    .collection('beaches')
    .select(BEACH_SELECT)
    .eq('status', 'published')
    .order('published_at', 'desc.nullslast')
    .order('created_at', 'desc');
}

/** A single published beach by slug, with embeds. */
export function beachBySlug(slug) {
  return baas
    .collection('beaches')
    .select(BEACH_SELECT)
    .eq('slug', slug)
    .eq('status', 'published')
    .single();
}

export { BEACH_SELECT };
