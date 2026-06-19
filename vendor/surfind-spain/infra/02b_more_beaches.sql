-- ============================================================
-- 02b_more_beaches.sql — 14 extra Spanish surf beaches (PostgreSQL)
--
-- Extends the original 16-beach catalog to 30 so the directory feels like a
-- real national surf map. Same shape as 02_seed.sql: location_id resolved by
-- slug, status published. Idempotent (NOT EXISTS guard on slug).
-- ============================================================
SET search_path TO public;

INSERT INTO beaches
    (name, slug, location_id, short_description, description,
     difficulty, status, published_at, latitude, longitude)
SELECT b.name, b.slug, l.id, b.short_description, b.description,
       b.difficulty, 'published', now(), b.latitude, b.longitude
FROM (VALUES
    ('Playa de Bakio', 'playa-de-bakio', 'bizkaia',
     'Arenal vizcaino abierto y consistente, buena opcion para progresar cerca de Bilbao.',
     'Bakio recibe mar con facilidad y reparte picos a lo largo de un arenal amplio. Funciona en muchos estados de marea y es habitual ver escuelas y surfistas de todos los niveles.',
     'intermediate', 43.4290000, -2.8060000),
    ('Playa de Laga', 'playa-de-laga', 'bizkaia',
     'Cala protegida de aguas turquesa junto a Ogono, con olas mas amables.',
     'Laga es una playa de postal, resguardada y con un entorno natural espectacular. Suele ofrecer olas mas manejables que los spots expuestos, ideal para dias de progresion.',
     'beginner', 43.4180000, -2.6300000),
    ('Playa de Deba', 'playa-de-deba', 'gipuzkoa',
     'Playa familiar de la costa guipuzcoana con olas tranquilas para iniciarse.',
     'Deba combina pueblo, ria y un arenal comodo. Es una buena eleccion para empezar, con dias pequenos y un ambiente relajado lejos de la masificacion.',
     'beginner', 43.2940000, -2.3520000),
    ('Playa de Meron', 'playa-de-meron', 'cantabria',
     'Arenal de San Vicente de la Barquera con picos variados y mucho espacio.',
     'Meron es una playa larga y expuesta del occidente cantabro. Su amplitud permite repartir surfistas y buscar el banco adecuado segun viento y marea.',
     'intermediate', 43.3870000, -4.3760000),
    ('Playa de Xago', 'playa-de-xago', 'asturias',
     'Playa asturiana entre dunas, potente y poco concurrida.',
     'Xago ofrece un entorno dunar salvaje y olas con energia. Es una opcion para surfistas con autonomia que busquen tranquilidad y picos cambiantes.',
     'intermediate', 43.5810000, -5.9180000),
    ('Playa de Tapia', 'playa-de-tapia', 'asturias',
     'Spot historico del surf asturiano, sede de campeonatos veteranos.',
     'Tapia de Casariego es un nombre clasico del surf del norte. Su rompiente de calidad y su comunidad surfera la convierten en parada obligada en el occidente asturiano.',
     'advanced', 43.5710000, -6.9420000),
    ('Playa de Nemina', 'playa-de-nemina', 'a-coruna',
     'Arenal salvaje de la Costa da Morte, expuesto y muy consistente.',
     'Nemina es una playa abierta al Atlantico, con olas potentes y poca presion de gente. Pide lectura de corrientes y respeto al mar, pero recompensa con calidad.',
     'advanced', 42.9740000, -9.2380000),
    ('Playa de Patos', 'playa-de-patos', 'pontevedra',
     'Spot rias-baixas muy querido, con escuelas y olas para todos.',
     'Patos, en Nigran, es uno de los puntos de referencia del surf gallego del sur. Su consistencia y sus servicios la hacen perfecta para aprender y para sesiones rapidas.',
     'beginner', 42.1560000, -8.8460000),
    ('Playa de Bolonia', 'playa-de-bolonia', 'cadiz',
     'Playa virgen de Tarifa con duna gigante y olas segun viento.',
     'Bolonia une patrimonio romano, una duna espectacular y un mar que funciona cuando el viento da tregua. Entorno protegido y ambiente muy natural.',
     'intermediate', 36.0890000, -5.7710000),
    ('Playa de Valdevaqueros', 'playa-de-valdevaqueros', 'cadiz',
     'Arenal enorme de Tarifa, dominio del viento y deportes de tabla.',
     'Valdevaqueros es sinonimo de viento. Aunque reina el kite y el windsurf, en ciertas condiciones tambien ofrece surf, con un arenal interminable y mucha luz.',
     'intermediate', 36.0680000, -5.6840000),
    ('Playa de La Cicer', 'playa-de-la-cicer', 'las-palmas',
     'Tramo surfero de Las Canteras en Las Palmas, urbano y consistente.',
     'La Cicer es la zona de olas de la gran playa urbana de Las Palmas. Surf accesible durante casi todo el ano, con ambiente local y agua calida.',
     'intermediate', 28.1380000, -15.4380000),
    ('Playa de Las Cucharas', 'playa-de-las-cucharas', 'las-palmas',
     'Spot de Costa Teguise en Lanzarote, escuela y olas regulares.',
     'Las Cucharas es uno de los puntos mas activos de Lanzarote para aprender. Olas regulares, escuelas y un entorno volcanico caracteristico.',
     'beginner', 29.0590000, -13.4980000),
    ('Playa de El Cabezo', 'playa-de-cabezo', 'santa-cruz-de-tenerife',
     'Reefbreak de El Medano, derecha potente para surfistas con nivel.',
     'El Cabezo es una rompiente de roca en El Medano, conocida por su derecha de calidad. Reservada para surfistas con experiencia por el fondo y la fuerza de la ola.',
     'advanced', 28.0430000, -16.5360000),
    ('Playa de La Barca', 'playa-de-la-barca', 'las-palmas',
     'Spot de Fuerteventura en Jandia, olas de calidad y agua clara.',
     'La Barca, en la peninsula de Jandia, ofrece olas potentes y un entorno de aguas transparentes. Un clasico del surf majorero para niveles medios y altos.',
     'intermediate', 28.0560000, -14.3290000)
) AS b(name, slug, location_id_slug, short_description, description, difficulty, latitude, longitude)
JOIN locations l ON l.slug = b.location_id_slug
WHERE NOT EXISTS (SELECT 1 FROM beaches x WHERE x.slug = b.slug);
