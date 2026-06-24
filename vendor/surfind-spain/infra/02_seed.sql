-- ============================================================
-- 02_seed.sql — Surfind Spain catalog seed (PostgreSQL)
--
-- Exact data from the Laravel seeders (LocationSeeder, AmenitySeeder,
-- BeachSeeder). Idempotent: every INSERT ... ON CONFLICT DO UPDATE/NOTHING
-- keyed on the table's unique key, so re-running converges. Slugs match
-- Laravel's Str::slug (lowercase, spaces → hyphens, accents stripped).
-- ============================================================
SET search_path TO public;

-- ── Locations: 24 provinces ───────────────────────────────────
INSERT INTO locations (name, slug) VALUES
    ('A Coruna',               'a-coruna'),
    ('Alicante',               'alicante'),
    ('Almeria',                'almeria'),
    ('Asturias',               'asturias'),
    ('Barcelona',              'barcelona'),
    ('Bizkaia',                'bizkaia'),
    ('Cadiz',                  'cadiz'),
    ('Cantabria',              'cantabria'),
    ('Castellon',              'castellon'),
    ('Ceuta',                  'ceuta'),
    ('Gipuzkoa',               'gipuzkoa'),
    ('Girona',                 'girona'),
    ('Granada',                'granada'),
    ('Huelva',                 'huelva'),
    ('Illes Balears',          'illes-balears'),
    ('Las Palmas',             'las-palmas'),
    ('Lugo',                   'lugo'),
    ('Malaga',                 'malaga'),
    ('Melilla',                'melilla'),
    ('Murcia',                 'murcia'),
    ('Pontevedra',             'pontevedra'),
    ('Santa Cruz de Tenerife', 'santa-cruz-de-tenerife'),
    ('Tarragona',              'tarragona'),
    ('Valencia',               'valencia')
ON CONFLICT (slug) DO UPDATE SET name = EXCLUDED.name;

-- ── Amenities: 8 ──────────────────────────────────────────────
-- Keyed on name (the seeder's updateOrCreate key); name is not unique in
-- the schema, so guard the insert against an existing row by name.
INSERT INTO amenities (name, icon)
SELECT v.name, v.icon
FROM (VALUES
    ('Duchas',               'shower'),
    ('Aseos',                'toilet'),
    ('Aparcamiento',         'parking'),
    ('Socorristas',          'lifebuoy'),
    ('Escuela de surf',      'surf-school'),
    ('Alquiler de material', 'rental'),
    ('Webcam',               'webcam'),
    ('Chiringuito',          'beach-bar')
) AS v(name, icon)
WHERE NOT EXISTS (SELECT 1 FROM amenities a WHERE a.name = v.name);

-- Keep icons in sync on re-run.
UPDATE amenities a SET icon = v.icon
FROM (VALUES
    ('Duchas',               'shower'),
    ('Aseos',                'toilet'),
    ('Aparcamiento',         'parking'),
    ('Socorristas',          'lifebuoy'),
    ('Escuela de surf',      'surf-school'),
    ('Alquiler de material', 'rental'),
    ('Webcam',               'webcam'),
    ('Chiringuito',          'beach-bar')
) AS v(name, icon)
WHERE a.name = v.name;

-- ── Beaches: 16 ───────────────────────────────────────────────
-- location_id resolved by slug; status published, published_at now().
INSERT INTO beaches
    (name, slug, location_id, short_description, description,
     difficulty, status, published_at, latitude, longitude)
SELECT b.name, b.slug, l.id, b.short_description, b.description,
       b.difficulty, 'published', now(), b.latitude, b.longitude
FROM (VALUES
    ('Playa de Somo', 'playa-de-somo', 'cantabria',
     'Un clasico cantabro con mucho espacio, ambiente surfero y condiciones amables para progresar.',
     E'Somo es una de las playas mas reconocibles del surf cantabro. Su arenal amplio reparte picos a lo largo de varios kilometros, lo que ayuda a encontrar espacio incluso en dias concurridos.\n\nFunciona como una opcion muy completa para aprender, mejorar tecnica y compartir sesiones con grupos de distinto nivel. Conviene revisar viento, marea y corrientes antes de entrar, porque el caracter de la playa cambia mucho segun el parte.',
     'beginner', 43.4569000, -3.7341000),
    ('Playa de Liencres', 'playa-de-liencres', 'cantabria',
     'Playa abierta y potente junto al parque dunar, con picos variables y mucha exposicion al Atlantico.',
     E'Liencres combina paisaje salvaje, dunas y una orientacion muy expuesta al mar de fondo. Es una playa agradecida cuando el viento acompana, pero puede ponerse exigente con tamano o corrientes marcadas.\n\nEs especialmente interesante para surfistas con cierta autonomia que busquen variedad de picos y una sensacion menos urbana. Para niveles iniciales es mejor elegir dias pequenos y entrar acompanado.',
     'intermediate', 43.4546000, -3.9635000),
    ('Playa de Rodiles', 'playa-de-rodiles', 'asturias',
     'Arenal asturiano de referencia, famoso por su ola de desembocadura cuando las condiciones cuadran.',
     E'Rodiles es una playa amplia y muy conocida dentro del surf asturiano. En condiciones normales ofrece picos de playa, pero su fama viene de la ola que puede formarse cerca de la ria, rapida y tecnica.\n\nNo es una playa para confiarse: corrientes, bancos de arena y cambios de marea pueden modificar mucho la sesion. Cuando esta potente, es mejor reservarla para surfistas con experiencia.',
     'advanced', 43.5326000, -5.3799000),
    ('Playa de Zarautz', 'playa-de-zarautz', 'gipuzkoa',
     'Gran playa urbana con cultura surf muy presente y picos para distintos niveles.',
     E'Zarautz es uno de los epicentros del surf en Euskadi. Su longitud permite repartir diferentes picos y su entorno urbano facilita una experiencia comoda antes y despues del bano.\n\nEs una buena opcion para aprender y progresar, aunque con mar fuerte puede ganar mucha energia. La afluencia suele ser alta, por lo que conviene respetar prioridades y elegir bien el pico segun el nivel.',
     'beginner', 43.2883000, -2.1718000),
    ('Playa de La Zurriola', 'playa-de-la-zurriola', 'gipuzkoa',
     'Spot urbano de Donostia con mucho ambiente, olas frecuentes y acceso muy sencillo.',
     E'La Zurriola es la playa mas surfera de San Sebastian. Su ubicacion en Gros la convierte en un punto muy accesible, con actividad durante gran parte del ano y una comunidad local muy visible.\n\nPuede ser una playa amable en dias pequenos, pero tambien exigente con mar de fondo y corriente. Es ideal para quien quiere combinar surf, ciudad y servicios cerca.',
     'intermediate', 43.3262000, -1.9737000),
    ('Playa de Mundaka', 'playa-de-mundaka', 'bizkaia',
     'Izquierda legendaria de rio, rapida y tubular, reservada para surfistas con experiencia.',
     E'Mundaka ocupa un lugar especial en la historia del surf europeo. Su ola izquierda puede ser larga, rapida y muy tecnica cuando coinciden mar, marea y viento.\n\nNo es un spot de iniciacion. El fondo, la corriente, la precision del pico y la concentracion de surfistas hacen que sea recomendable solo para personas con nivel alto y conocimiento del entorno.',
     'advanced', 43.4077000, -2.6996000),
    ('Playa de Sopelana', 'playa-de-sopelana', 'bizkaia',
     'Acantilados, picos consistentes y ambiente surfero cerca de Bilbao.',
     E'Sopelana es una referencia para surfistas de Bizkaia por su consistencia y por la variedad de bancos que pueden aparecer. El entorno de acantilados aporta una identidad muy marcada.\n\nSuele ser una playa interesante para nivel intermedio, aunque algunos dias puede ponerse seria. Es importante observar corrientes, zonas de roca y la evolucion de la marea.',
     'intermediate', 43.3893000, -2.9946000),
    ('Playa de Razo', 'playa-de-razo', 'a-coruna',
     'Arenal abierto de Costa da Morte con olas constantes y mucho margen para moverse.',
     E'Razo es una playa amplia y muy expuesta, con un caracter atlantico claro. La longitud del arenal permite buscar diferentes zonas segun bancos, viento y marea.\n\nEs una opcion muy completa para surfistas que ya se manejan con autonomia. En dias pequenos puede ser accesible, pero con mar fuerte exige lectura de corrientes y prudencia.',
     'intermediate', 43.2941000, -8.6850000),
    ('Playa de Pantin', 'playa-de-pantin', 'a-coruna',
     'Spot gallego reconocido por competiciones, con ola potente y mucha exposicion.',
     E'Pantin es uno de los nombres clave del surf gallego. Su playa abierta recibe mar con facilidad y puede ofrecer olas de mucha calidad cuando las condiciones se ordenan.\n\nEs recomendable para surfistas con experiencia, sobre todo en dias de tamano. La energia del Atlantico, las corrientes y la variabilidad de los bancos piden entrar con criterio.',
     'advanced', 43.6266000, -8.1075000),
    ('Playa de Doninos', 'playa-de-doninos', 'a-coruna',
     'Playa salvaje cerca de Ferrol, con picos potentes y un entorno natural muy abierto.',
     E'Doninos ofrece un escenario amplio, expuesto y con mucha personalidad. Su orientacion capta mar con facilidad, lo que la convierte en una playa frecuente para sesiones con energia.\n\nPuede funcionar para niveles medios en dias controlados, pero no conviene subestimar su fuerza. Las corrientes y el tamano cambiante hacen recomendable observar antes de entrar.',
     'intermediate', 43.4956000, -8.3206000),
    ('Playa de El Palmar', 'playa-de-el-palmar', 'cadiz',
     'Arenal gaditano largo y accesible, muy popular para aprender y disfrutar olas suaves.',
     E'El Palmar es uno de los spots mas conocidos de Cadiz por su ambiente relajado y su playa extensa. En dias pequenos y ordenados es una gran opcion para iniciarse o mejorar maniobras basicas.\n\nLa experiencia cambia bastante con viento y mareas, asi que conviene elegir bien la hora. En temporada alta puede llenarse, pero la longitud del arenal ayuda a repartir banistas y surfistas.',
     'beginner', 36.2350000, -6.0700000),
    ('Playa de Los Lances', 'playa-de-los-lances', 'cadiz',
     'Playa amplia de Tarifa, marcada por el viento y con sesiones variables segun el dia.',
     E'Los Lances es una playa enorme y muy ligada al viento. Aunque Tarifa se asocia mas al kite y windsurf, tambien puede ofrecer sesiones de surf cuando entra mar y el viento acompana.\n\nEs una playa util para surfistas intermedios que sepan leer el parte y adaptarse. La amplitud del arenal y los servicios cercanos facilitan organizar la sesion.',
     'intermediate', 36.0314000, -5.6333000),
    ('Playa de Famara', 'playa-de-famara', 'las-palmas',
     'Icono de Lanzarote, con mucho espacio, paisaje volcanico y ambiente de escuela.',
     E'Famara combina un entorno espectacular bajo el risco con una playa amplia y muy surfera. Su espacio y oferta de escuelas la hacen especialmente atractiva para aprender o retomar confianza.\n\nAun asi, es una playa expuesta al viento y con corrientes que deben tomarse en serio. Para principiantes, lo mejor es entrar con supervision y escoger dias moderados.',
     'beginner', 29.1189000, -13.5544000),
    ('Playa de Las Americas', 'playa-de-las-americas', 'santa-cruz-de-tenerife',
     'Zona surfera de Tenerife con olas de roca, consistentes y tecnicas.',
     E'Las Americas concentra varios picos sobre fondo volcanico en una zona muy activa del sur de Tenerife. Puede ofrecer olas de calidad y bastante consistencia durante la temporada adecuada.\n\nEl fondo de roca, la afluencia y la precision necesaria hacen que no sea el mejor lugar para iniciarse. Es un entorno mas apropiado para surfistas con experiencia y buena lectura del spot.',
     'advanced', 28.0616000, -16.7338000),
    ('Playa de El Medano', 'playa-de-el-medano', 'santa-cruz-de-tenerife',
     'Playa ventosa y abierta, conocida por deportes de agua y sesiones cambiantes.',
     E'El Medano es una playa muy ligada al viento y a los deportes nauticos. Cuando las condiciones se alinean, tambien permite sesiones de surf en un entorno amplio y facil de acceder.\n\nPor su exposicion y actividad en el agua, es recomendable escoger bien la zona y el momento. Puede ser muy divertida para nivel intermedio, especialmente si se entiende el papel del viento.',
     'intermediate', 28.0450000, -16.5367000),
    ('Playa de Mazagon', 'playa-de-mazagon', 'huelva',
     'Costa atlantica onubense con arenal amplio, sesiones tranquilas y mucho espacio.',
     E'Mazagon ofrece un entorno abierto y arenoso en la costa de Huelva. No tiene la consistencia de otros destinos mas expuestos, pero puede dar sesiones agradables con mar ordenado.\n\nEs una opcion tranquila para dias suaves, especialmente para surfistas que buscan espacio y poca presion en el agua. La lectura del parte es clave para no encontrar el mar demasiado plano.',
     'beginner', 37.1339000, -6.8287000)
) AS b(name, slug, location_slug, short_description, description,
       difficulty, latitude, longitude)
JOIN locations l ON l.slug = b.location_slug
ON CONFLICT (slug) DO UPDATE SET
    name              = EXCLUDED.name,
    location_id       = EXCLUDED.location_id,
    short_description = EXCLUDED.short_description,
    description       = EXCLUDED.description,
    difficulty        = EXCLUDED.difficulty,
    status            = EXCLUDED.status,
    latitude          = EXCLUDED.latitude,
    longitude         = EXCLUDED.longitude;

-- ── Amenity ↔ Beach links ─────────────────────────────────────
-- Resolve both sides by their natural keys (beach slug, amenity name).
INSERT INTO amenity_beach (beach_id, amenity_id)
SELECT bch.id, am.id
FROM (VALUES
    ('playa-de-somo',          'Duchas'),
    ('playa-de-somo',          'Aseos'),
    ('playa-de-somo',          'Aparcamiento'),
    ('playa-de-somo',          'Socorristas'),
    ('playa-de-somo',          'Escuela de surf'),
    ('playa-de-somo',          'Alquiler de material'),
    ('playa-de-somo',          'Webcam'),
    ('playa-de-somo',          'Chiringuito'),
    ('playa-de-liencres',      'Aparcamiento'),
    ('playa-de-liencres',      'Socorristas'),
    ('playa-de-rodiles',       'Aparcamiento'),
    ('playa-de-rodiles',       'Socorristas'),
    ('playa-de-rodiles',       'Chiringuito'),
    ('playa-de-zarautz',       'Duchas'),
    ('playa-de-zarautz',       'Aseos'),
    ('playa-de-zarautz',       'Aparcamiento'),
    ('playa-de-zarautz',       'Socorristas'),
    ('playa-de-zarautz',       'Escuela de surf'),
    ('playa-de-zarautz',       'Alquiler de material'),
    ('playa-de-zarautz',       'Webcam'),
    ('playa-de-zarautz',       'Chiringuito'),
    ('playa-de-la-zurriola',   'Duchas'),
    ('playa-de-la-zurriola',   'Aseos'),
    ('playa-de-la-zurriola',   'Aparcamiento'),
    ('playa-de-la-zurriola',   'Socorristas'),
    ('playa-de-la-zurriola',   'Escuela de surf'),
    ('playa-de-la-zurriola',   'Alquiler de material'),
    ('playa-de-la-zurriola',   'Webcam'),
    ('playa-de-mundaka',       'Aparcamiento'),
    ('playa-de-mundaka',       'Webcam'),
    ('playa-de-mundaka',       'Chiringuito'),
    ('playa-de-sopelana',      'Duchas'),
    ('playa-de-sopelana',      'Aparcamiento'),
    ('playa-de-sopelana',      'Socorristas'),
    ('playa-de-sopelana',      'Escuela de surf'),
    ('playa-de-sopelana',      'Alquiler de material'),
    ('playa-de-sopelana',      'Chiringuito'),
    ('playa-de-razo',          'Duchas'),
    ('playa-de-razo',          'Aparcamiento'),
    ('playa-de-razo',          'Socorristas'),
    ('playa-de-razo',          'Escuela de surf'),
    ('playa-de-razo',          'Alquiler de material'),
    ('playa-de-razo',          'Chiringuito'),
    ('playa-de-pantin',        'Aparcamiento'),
    ('playa-de-pantin',        'Socorristas'),
    ('playa-de-pantin',        'Webcam'),
    ('playa-de-pantin',        'Chiringuito'),
    ('playa-de-doninos',       'Aparcamiento'),
    ('playa-de-doninos',       'Socorristas'),
    ('playa-de-doninos',       'Chiringuito'),
    ('playa-de-el-palmar',     'Aparcamiento'),
    ('playa-de-el-palmar',     'Socorristas'),
    ('playa-de-el-palmar',     'Escuela de surf'),
    ('playa-de-el-palmar',     'Alquiler de material'),
    ('playa-de-el-palmar',     'Chiringuito'),
    ('playa-de-los-lances',    'Duchas'),
    ('playa-de-los-lances',    'Aparcamiento'),
    ('playa-de-los-lances',    'Socorristas'),
    ('playa-de-los-lances',    'Escuela de surf'),
    ('playa-de-los-lances',    'Alquiler de material'),
    ('playa-de-los-lances',    'Chiringuito'),
    ('playa-de-famara',        'Aparcamiento'),
    ('playa-de-famara',        'Socorristas'),
    ('playa-de-famara',        'Escuela de surf'),
    ('playa-de-famara',        'Alquiler de material'),
    ('playa-de-famara',        'Chiringuito'),
    ('playa-de-las-americas',  'Aseos'),
    ('playa-de-las-americas',  'Aparcamiento'),
    ('playa-de-las-americas',  'Escuela de surf'),
    ('playa-de-las-americas',  'Alquiler de material'),
    ('playa-de-las-americas',  'Webcam'),
    ('playa-de-las-americas',  'Chiringuito'),
    ('playa-de-el-medano',     'Duchas'),
    ('playa-de-el-medano',     'Aseos'),
    ('playa-de-el-medano',     'Aparcamiento'),
    ('playa-de-el-medano',     'Socorristas'),
    ('playa-de-el-medano',     'Escuela de surf'),
    ('playa-de-el-medano',     'Alquiler de material'),
    ('playa-de-el-medano',     'Chiringuito'),
    ('playa-de-mazagon',       'Duchas'),
    ('playa-de-mazagon',       'Aseos'),
    ('playa-de-mazagon',       'Aparcamiento'),
    ('playa-de-mazagon',       'Socorristas'),
    ('playa-de-mazagon',       'Chiringuito')
) AS link(beach_slug, amenity_name)
JOIN beaches   bch ON bch.slug = link.beach_slug
JOIN amenities am  ON am.name  = link.amenity_name
ON CONFLICT (beach_id, amenity_id) DO NOTHING;
