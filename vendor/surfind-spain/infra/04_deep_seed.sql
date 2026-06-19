-- ============================================================
-- 04_deep_seed.sql — Surfind Spain DEEP seed (PostgreSQL)
--
-- Fills the surf-intel + media columns on the 16 seeded beaches, points each
-- at its generated SVG art (cover + 2 gallery) and a curated YouTube surf clip,
-- and loads the /blog articles + a handful of public surf_reports.
--
-- Idempotent: UPDATE … WHERE slug; gallery + articles guard with NOT EXISTS;
-- reports re-seed by deleting prior seed rows first. Run after 02_seed.sql.
-- ============================================================
SET search_path TO public;

-- ── 1) Per-beach surf intel + cover + curated video ───────────
-- 4 curated generic Spanish/surf YouTube clips, assigned round-robin by row.
WITH vids(i, url) AS (VALUES
    (0, 'https://www.youtube.com/watch?v=Q7mMzNHbBSc'),
    (1, 'https://www.youtube.com/watch?v=AdSjlNEjT5E'),
    (2, 'https://www.youtube.com/watch?v=NW0Afx7Zf4w'),
    (3, 'https://www.youtube.com/watch?v=8Z3yJ4M4gAk')
),
intel(slug, break_type, wave_direction, best_tide, best_season, bottom_type,
      wave_quality, crowd_level, water_temp_c, hazards, vi) AS (VALUES
    ('playa-de-somo',         'Beachbreak', 'Izquierda y derecha', 'Media subiendo', 'Otono-Invierno', 'Arena',      4, 'Alto',  '14-18 C', 'Corrientes en marea baja', 0),
    ('playa-de-liencres',     'Beachbreak', 'Picos variables',     'Media',          'Otono',          'Arena',      4, 'Medio', '13-17 C', 'Corrientes, rocas laterales', 1),
    ('playa-de-rodiles',      'Rivermouth', 'Izquierda',           'Media subiendo', 'Otono',          'Arena',      5, 'Medio', '13-17 C', 'Corriente de ria, bancos', 2),
    ('playa-de-zarautz',      'Beachbreak', 'Izquierda y derecha', 'Todas',          'Otono-Invierno', 'Arena',      3, 'Alto',  '14-18 C', 'Aglomeracion, prioridades', 3),
    ('playa-de-la-zurriola',  'Beachbreak', 'Picos variables',     'Media',          'Otono',          'Arena',      4, 'Alto',  '14-18 C', 'Corriente, mucha gente', 0),
    ('playa-de-mundaka',      'Rivermouth', 'Izquierda',           'Baja subiendo',  'Otono-Invierno', 'Arena/Ria',  5, 'Alto',  '13-17 C', 'Ola tecnica, localismo, corriente', 1),
    ('playa-de-sopelana',     'Beachbreak', 'Picos variables',     'Media',          'Otono',          'Arena',      4, 'Medio', '13-17 C', 'Rocas, acantilados, mareas', 2),
    ('playa-de-razo',         'Beachbreak', 'Izquierda y derecha', 'Todas',          'Todo el ano',    'Arena',      4, 'Bajo',  '12-16 C', 'Corrientes con mar grande', 3),
    ('playa-de-pantin',       'Beachbreak', 'Derecha',             'Media',          'Otono',          'Arena',      5, 'Medio', '12-16 C', 'Olas potentes, corrientes', 0),
    ('playa-de-doninos',      'Beachbreak', 'Picos variables',     'Media',          'Otono-Invierno', 'Arena',      4, 'Bajo',  '12-16 C', 'Exposicion atlantica, corrientes', 1),
    ('playa-de-el-palmar',    'Beachbreak', 'Izquierda y derecha', 'Media',          'Otono-Invierno', 'Arena',      3, 'Alto',  '16-21 C', 'Viento de levante, masificacion', 2),
    ('playa-de-los-lances',   'Beachbreak', 'Picos variables',     'Media',          'Primavera',      'Arena',      3, 'Medio', '16-21 C', 'Viento fuerte, kite/windsurf', 3),
    ('playa-de-famara',       'Beachbreak', 'Izquierda y derecha', 'Media',          'Invierno',       'Arena',      4, 'Alto',  '18-22 C', 'Viento, corrientes, escuelas', 0),
    ('playa-de-las-americas', 'Reefbreak',  'Derecha',             'Media subiendo', 'Invierno',       'Roca',       4, 'Medio', '19-23 C', 'Fondo de roca, erizos', 1),
    ('playa-de-el-medano',    'Beachbreak', 'Picos variables',     'Media',          'Todo el ano',    'Arena',      3, 'Medio', '19-23 C', 'Viento constante, kite', 2),
    ('playa-de-mazagon',      'Beachbreak', 'Picos variables',     'Media',          'Otono-Invierno', 'Arena',      3, 'Bajo',  '16-21 C', 'Olas pequenas, corrientes', 3),
    ('playa-de-bakio',        'Beachbreak', 'Picos variables',     'Media',          'Otono',          'Arena',      4, 'Medio', '13-17 C', 'Corrientes con mar grande', 0),
    ('playa-de-laga',         'Beachbreak', 'Izquierda y derecha', 'Media',          'Otono',          'Arena',      3, 'Bajo',  '14-18 C', 'Cala protegida, rocas', 1),
    ('playa-de-deba',         'Beachbreak', 'Picos variables',     'Media',          'Otono-Invierno', 'Arena',      3, 'Bajo',  '14-18 C', 'Olas suaves, ria', 2),
    ('playa-de-meron',        'Beachbreak', 'Picos variables',     'Todas',          'Otono',          'Arena',      4, 'Bajo',  '13-17 C', 'Exposicion, corrientes', 3),
    ('playa-de-xago',         'Beachbreak', 'Picos variables',     'Media',          'Otono-Invierno', 'Arena',      4, 'Bajo',  '12-16 C', 'Dunas, corrientes', 0),
    ('playa-de-tapia',        'Reefbreak',  'Izquierda y derecha', 'Media subiendo', 'Otono-Invierno', 'Roca/Arena', 5, 'Medio', '12-16 C', 'Fondo de roca, potencia', 1),
    ('playa-de-nemina',       'Beachbreak', 'Picos variables',     'Media',          'Otono',          'Arena',      4, 'Bajo',  '12-16 C', 'Salvaje, corrientes fuertes', 2),
    ('playa-de-patos',        'Beachbreak', 'Izquierda y derecha', 'Media',          'Otono-Invierno', 'Arena',      4, 'Alto',  '13-17 C', 'Masificacion, rocas laterales', 3),
    ('playa-de-bolonia',      'Beachbreak', 'Picos variables',     'Media',          'Otono',          'Arena',      3, 'Bajo',  '16-21 C', 'Viento de levante', 0),
    ('playa-de-valdevaqueros','Beachbreak', 'Picos variables',     'Media',          'Primavera',      'Arena',      3, 'Alto',  '16-21 C', 'Viento muy fuerte, kite', 1),
    ('playa-de-la-cicer',     'Beachbreak', 'Izquierda y derecha', 'Media',          'Todo el ano',    'Arena',      4, 'Alto',  '19-23 C', 'Urbano, mucha gente', 2),
    ('playa-de-las-cucharas', 'Beachbreak', 'Picos variables',     'Media',          'Invierno',       'Arena',      3, 'Alto',  '18-22 C', 'Escuelas, viento', 3),
    ('playa-de-cabezo',       'Reefbreak',  'Derecha',             'Media subiendo', 'Todo el ano',    'Roca',       5, 'Medio', '19-23 C', 'Fondo de roca, erizos, viento', 0),
    ('playa-de-la-barca',     'Reefbreak',  'Izquierda y derecha', 'Media',          'Invierno',       'Roca/Arena', 4, 'Medio', '19-23 C', 'Fondo mixto, corrientes', 1)
)
UPDATE beaches b SET
    break_type     = i.break_type,
    wave_direction = i.wave_direction,
    best_tide      = i.best_tide,
    best_season    = i.best_season,
    bottom_type    = i.bottom_type,
    wave_quality   = i.wave_quality,
    crowd_level    = i.crowd_level,
    water_temp_c   = i.water_temp_c,
    hazards        = i.hazards,
    cover_image    = '/media/beaches/' || i.slug || '-cover.svg',
    video_url      = v.url
FROM intel i
JOIN vids v ON v.i = i.vi
WHERE b.slug = i.slug;

-- ── 2) Gallery images (2 per beach) → generated SVGs ──────────
INSERT INTO beach_images (beach_id, source_type, external_url, is_cover, sort_order, alt_text)
SELECT b.id, 'url', '/media/beaches/' || b.slug || '-cover.svg', true, 0, b.name || ' (portada)'
FROM beaches b
WHERE b.cover_image IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM beach_images x WHERE x.beach_id = b.id AND x.is_cover);

INSERT INTO beach_images (beach_id, source_type, external_url, is_cover, sort_order, alt_text)
SELECT b.id, 'url', '/media/beaches/' || b.slug || '-' || g.n || '.svg', false, g.n, b.name || ' (galeria ' || g.n || ')'
FROM beaches b CROSS JOIN (VALUES (1), (2)) AS g(n)
WHERE b.cover_image IS NOT NULL
  AND NOT EXISTS (
    SELECT 1 FROM beach_images x
    WHERE x.beach_id = b.id AND x.external_url = '/media/beaches/' || b.slug || '-' || g.n || '.svg'
  );

-- ── 3) Articles (the /blog) — markdown bodies ─────────────────
INSERT INTO articles (slug, title, excerpt, body, cover_image, author_name, beach_id, tags, read_minutes, published, published_at)
SELECT v.slug, v.title, v.excerpt, v.body, v.cover, v.author,
       (SELECT id FROM beaches WHERE slug = v.beach_slug), v.tags, v.minutes, true, now() - (v.days || ' days')::interval
FROM (VALUES
    ('leer-mundaka',
     'Mundaka: como leer la izquierda mas famosa de Europa',
     'Marea, viento y respeto: lo esencial antes de remar en la ola de la ria.',
     E'# Mundaka, la izquierda de la ria\n\nMundaka es una de esas olas que **definen un lugar**. Cuando entra mar de fondo del noroeste y la marea acompana, la izquierda se alarga y se vuelve rapida y tubular.\n\n## Cuando funciona\n\n- Mar de fondo de **NO** con periodo largo.\n- Marea **baja subiendo** suele ordenar mejor los bancos.\n- Viento **sur** (terral) para una pared limpia.\n\n## Antes de remar\n\n1. Observa al menos quince minutos desde el puerto.\n2. Respeta la **prioridad** y el orden del pico.\n3. Si dudas de tu nivel, ese dia no es tu dia.\n\nMundaka premia la **paciencia** y castiga la prisa. Para un buen recurso visual, mira la [comunidad](/comunidad) y los reportes en vivo.',
     '/media/beaches/playa-de-mundaka-cover.svg', 'Redaccion Surfind', 'playa-de-mundaka',
     ARRAY['avanzado','rivermouth','euskadi'], 6, 4),
    ('iniciacion-somo',
     'Empezar en Somo: tu primera semana de surf',
     'Un arenal amable, mucho espacio y escuelas: por que Somo es ideal para aprender.',
     E'# Tu primera semana en Somo\n\nSomo reparte picos a lo largo de varios kilometros, asi que **siempre hay sitio** para practicar sin agobios.\n\n## Que necesitas\n\n- Una tabla de **espuma** grande y estable.\n- Neopreno de 3/2 o 4/3 segun la epoca.\n- Ganas de repetir el *pop-up* mil veces.\n\n## Plan de la semana\n\n- **Dia 1-2:** remada y posicion en la tabla.\n- **Dia 3-4:** ponerse de pie en espuma.\n- **Dia 5+:** buscar la ola un poco antes de que rompa.\n\nElige **marea media** y dias pequenos. Cuando tengas confianza, anota tus sesiones en tu [bitacora](/bitacora).',
     '/media/beaches/playa-de-somo-cover.svg', 'Escuela Surfind', 'playa-de-somo',
     ARRAY['principiante','cantabria','escuela'], 5, 9),
    ('mareas-y-viento',
     'Mareas, viento y periodo: leer un parte de surf sin morir en el intento',
     'Tres variables que cambian una sesion por completo, explicadas en simple.',
     E'# Leer el parte de surf\n\nUn parte da miedo hasta que entiendes **tres numeros**.\n\n## 1. Altura y periodo\n\nNo es lo mismo 1 m con periodo **6 s** (viento, desordenado) que 1 m con **14 s** (mar de fondo, con fuerza). El periodo manda.\n\n## 2. Viento\n\n- **Offshore / terral:** peina la ola, pared limpia. Lo mejor.\n- **Onshore / mar:** desordena y revienta antes. Lo peor.\n\n## 3. Marea\n\nCada playa tiene su **mejor marea**. En *beachbreaks* la media suele funcionar; en derechas de roca, ojo con la baja.\n\nCon esto ya puedes elegir **donde y cuando**. El resto es agua.',
     '/media/beaches/playa-de-liencres-cover.svg', 'Redaccion Surfind', NULL,
     ARRAY['tecnica','meteorologia'], 7, 14),
    ('costa-da-morte',
     'Costa da Morte: surf salvaje en Razo, Pantin y Doninos',
     'Olas potentes, poca gente y mucho Atlantico en el oeste gallego.',
     E'# Costa da Morte, surf de verdad\n\nGalicia esconde algunos de los arenales **mas consistentes** de la peninsula. Aqui el Atlantico no se anda con rodeos.\n\n## Tres clasicos\n\n- **Razo:** abierto, espacio de sobra para moverse.\n- **Pantin:** ola de competicion, potente cuando ordena.\n- **Doninos:** salvaje, cerca de Ferrol, entorno natural.\n\n## Consejo\n\nVienen con **mas energia** de lo que parece desde la arena. Observa las corrientes y entra acompanado los dias grandes.\n\nMenos masificacion, mas mar. Asi es el surf gallego.',
     '/media/beaches/playa-de-razo-cover.svg', 'Redaccion Surfind', 'playa-de-razo',
     ARRAY['intermedio','galicia','atlantico'], 6, 20)
) AS v(slug, title, excerpt, body, cover, author, beach_slug, tags, minutes, days)
WHERE NOT EXISTS (SELECT 1 FROM articles a WHERE a.slug = v.slug);

-- ── 3b) Per-beach guide articles (slug guia-<stem>) ──────────
-- One short markdown guide per beach so every detail page has a "Guía de la
-- playa" link, and the catalog clears the >=20 published-articles bar.
INSERT INTO articles (slug, title, excerpt, body, cover_image, author_name, beach_id, tags, read_minutes, published, published_at)
SELECT 'guia-' || regexp_replace(b.slug, '^playa-de-', ''),
       'Guía de ' || regexp_replace(initcap(replace(regexp_replace(b.slug, '^playa-de-', ''), '-', ' ')), '\s+', ' ', 'g'),
       coalesce(b.short_description, 'Todo lo que necesitas saber antes de surfear esta playa.'),
       E'# ' || b.name || E'\n\n' ||
         coalesce(b.description, 'Una playa de la costa española para disfrutar del surf.') || E'\n\n' ||
         E'## Condiciones\n\n' ||
         E'- **Rompiente:** ' || coalesce(b.break_type, 'variable') || E'\n' ||
         E'- **Dirección:** ' || coalesce(b.wave_direction, 'variable') || E'\n' ||
         E'- **Mejor marea:** ' || coalesce(b.best_tide, 'media') || E'\n' ||
         E'- **Mejor temporada:** ' || coalesce(b.best_season, 'otoño-invierno') || E'\n' ||
         E'- **Fondo:** ' || coalesce(b.bottom_type, 'arena') || E'\n\n' ||
         E'## Peligros\n\n' || coalesce(b.hazards, 'Revisa siempre corrientes y marea antes de entrar.') || E'\n\n' ||
         E'Consulta los [reportes en vivo](/reportes) y la [comunidad](/comunidad) antes de tu sesión.',
       b.cover_image, 'Redacción Surfind', b.id,
       ARRAY['guia', coalesce(lower(b.difficulty), 'surf')], greatest(coalesce(b.wave_quality, 3), 3), true,
       now() - (b.id || ' days')::interval
FROM beaches b
WHERE b.status = 'published'
  AND NOT EXISTS (
    SELECT 1 FROM articles a WHERE a.slug = 'guia-' || regexp_replace(b.slug, '^playa-de-', '')
  );

-- ── 4) Public surf_reports (seed the live feed) ───────────────
DELETE FROM surf_reports WHERE author_name LIKE 'Demo %';
INSERT INTO surf_reports (beach_id, author_name, wave_height_m, period_s, wind, crowd, quality, comment, created_at)
SELECT b.id, v.author, v.height, v.period, v.wind, v.crowd, v.quality, v.comment, now() - (v.mins || ' minutes')::interval
FROM (VALUES
    ('playa-de-somo',     'Demo Lucia',  1.2, 11, 'Terral flojo',  'Medio', 4, 'Picos limpios en la zona central, marea subiendo.', 35),
    ('playa-de-mundaka',  'Demo Iker',   1.8, 14, 'Sur',           'Alto',  5, 'La ria entra larga hoy, dia historico.', 80),
    ('playa-de-pantin',   'Demo Noa',    1.5, 12, 'Variable',      'Bajo',  4, 'Derecha potente, poca gente a primera hora.', 140),
    ('playa-de-el-palmar','Demo Marcos', 0.8,  9, 'Levante',       'Alto',  3, 'Pequeno pero divertido para iniciarse.', 220)
) AS v(slug, author, height, period, wind, crowd, quality, comment, mins)
JOIN beaches b ON b.slug = v.slug;
