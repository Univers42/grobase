// VideoEmbed.jsx — a "watch surf videos of this beach" card. Uses the beach's
// own cover art as the poster (no external thumbnail to 404) and opens a real
// YouTube search for the spot in a new tab — so it always shows REAL footage of
// the actual beach, with no hard-coded (possibly dead) video ids.
const ytSearch = (q) => `https://www.youtube.com/results?search_query=${encodeURIComponent(q)}`;

/** Video card for a beach: cover poster + play overlay → YouTube search for the spot. */
export default function VideoEmbed({ title, poster, region }) {
  const query = [title, region, 'surf'].filter(Boolean).join(' ');
  return (
    <section className="panel overflow-hidden">
      <a
        href={ytSearch(query)}
        target="_blank"
        rel="noopener noreferrer"
        className="group relative block aspect-video bg-ocean-deep"
        aria-label={`Ver vídeos de surf de ${title} en YouTube`}
      >
        {poster && (
          <img
            src={poster}
            alt=""
            loading="lazy"
            className="absolute inset-0 h-full w-full object-cover opacity-85 transition group-hover:opacity-100"
          />
        )}
        <span className="absolute inset-0 grid place-items-center">
          <span className="grid size-16 place-items-center rounded-full bg-white/90 text-2xl text-ocean shadow-xl transition group-hover:scale-110">
            ▶
          </span>
        </span>
        <span className="absolute inset-x-0 bottom-0 bg-gradient-to-t from-ocean-deep/85 to-transparent p-4 text-sm font-bold text-white">
          Ver vídeos de surf de {title} en YouTube
        </span>
      </a>
    </section>
  );
}
