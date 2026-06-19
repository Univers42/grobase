<?php

namespace Database\Seeders;

use App\Models\Amenity;
use App\Models\Beach;
use App\Models\Location;
use App\Models\User;
use Illuminate\Database\Seeder;

class BeachSeeder extends Seeder
{
    /**
     * Run the database seeds.
     */
    public function run(): void
    {
        $admin = User::where('email', 'admin@surfind.es')->first();
        $locations = Location::all()->keyBy('slug');
        $amenities = Amenity::all()->keyBy('name');

        foreach ($this->beaches() as $beachData) {
            $beach = Beach::updateOrCreate(
                ['slug' => $beachData['slug']],
                [
                    'name' => $beachData['name'],
                    'location_id' => $locations->get($beachData['location_slug'])->id,
                    'created_by' => $admin?->id,
                    'short_description' => $beachData['short_description'],
                    'description' => $beachData['description'],
                    'difficulty' => $beachData['difficulty'],
                    'status' => 'published',
                    'published_at' => now(),
                    'latitude' => $beachData['latitude'],
                    'longitude' => $beachData['longitude'],
                ],
            );

            $beach->amenities()->sync(
                collect($beachData['amenities'])
                    ->map(fn (string $name) => $amenities->get($name)->id)
                    ->all(),
            );
        }
    }

    private function beaches(): array
    {
        return [
            [
                'name' => 'Playa de Somo',
                'slug' => 'playa-de-somo',
                'location_slug' => 'cantabria',
                'short_description' => 'Un clasico cantabro con mucho espacio, ambiente surfero y condiciones amables para progresar.',
                'description' => "Somo es una de las playas mas reconocibles del surf cantabro. Su arenal amplio reparte picos a lo largo de varios kilometros, lo que ayuda a encontrar espacio incluso en dias concurridos.\n\nFunciona como una opcion muy completa para aprender, mejorar tecnica y compartir sesiones con grupos de distinto nivel. Conviene revisar viento, marea y corrientes antes de entrar, porque el caracter de la playa cambia mucho segun el parte.",
                'difficulty' => 'beginner',
                'latitude' => 43.4569000,
                'longitude' => -3.7341000,
                'amenities' => ['Duchas', 'Aseos', 'Aparcamiento', 'Socorristas', 'Escuela de surf', 'Alquiler de material', 'Webcam', 'Chiringuito'],
            ],
            [
                'name' => 'Playa de Liencres',
                'slug' => 'playa-de-liencres',
                'location_slug' => 'cantabria',
                'short_description' => 'Playa abierta y potente junto al parque dunar, con picos variables y mucha exposicion al Atlantico.',
                'description' => "Liencres combina paisaje salvaje, dunas y una orientacion muy expuesta al mar de fondo. Es una playa agradecida cuando el viento acompana, pero puede ponerse exigente con tamano o corrientes marcadas.\n\nEs especialmente interesante para surfistas con cierta autonomia que busquen variedad de picos y una sensacion menos urbana. Para niveles iniciales es mejor elegir dias pequenos y entrar acompanado.",
                'difficulty' => 'intermediate',
                'latitude' => 43.4546000,
                'longitude' => -3.9635000,
                'amenities' => ['Aparcamiento', 'Socorristas'],
            ],
            [
                'name' => 'Playa de Rodiles',
                'slug' => 'playa-de-rodiles',
                'location_slug' => 'asturias',
                'short_description' => 'Arenal asturiano de referencia, famoso por su ola de desembocadura cuando las condiciones cuadran.',
                'description' => "Rodiles es una playa amplia y muy conocida dentro del surf asturiano. En condiciones normales ofrece picos de playa, pero su fama viene de la ola que puede formarse cerca de la ria, rapida y tecnica.\n\nNo es una playa para confiarse: corrientes, bancos de arena y cambios de marea pueden modificar mucho la sesion. Cuando esta potente, es mejor reservarla para surfistas con experiencia.",
                'difficulty' => 'advanced',
                'latitude' => 43.5326000,
                'longitude' => -5.3799000,
                'amenities' => ['Aparcamiento', 'Socorristas', 'Chiringuito'],
            ],
            [
                'name' => 'Playa de Zarautz',
                'slug' => 'playa-de-zarautz',
                'location_slug' => 'gipuzkoa',
                'short_description' => 'Gran playa urbana con cultura surf muy presente y picos para distintos niveles.',
                'description' => "Zarautz es uno de los epicentros del surf en Euskadi. Su longitud permite repartir diferentes picos y su entorno urbano facilita una experiencia comoda antes y despues del bano.\n\nEs una buena opcion para aprender y progresar, aunque con mar fuerte puede ganar mucha energia. La afluencia suele ser alta, por lo que conviene respetar prioridades y elegir bien el pico segun el nivel.",
                'difficulty' => 'beginner',
                'latitude' => 43.2883000,
                'longitude' => -2.1718000,
                'amenities' => ['Duchas', 'Aseos', 'Aparcamiento', 'Socorristas', 'Escuela de surf', 'Alquiler de material', 'Webcam', 'Chiringuito'],
            ],
            [
                'name' => 'Playa de La Zurriola',
                'slug' => 'playa-de-la-zurriola',
                'location_slug' => 'gipuzkoa',
                'short_description' => 'Spot urbano de Donostia con mucho ambiente, olas frecuentes y acceso muy sencillo.',
                'description' => "La Zurriola es la playa mas surfera de San Sebastian. Su ubicacion en Gros la convierte en un punto muy accesible, con actividad durante gran parte del ano y una comunidad local muy visible.\n\nPuede ser una playa amable en dias pequenos, pero tambien exigente con mar de fondo y corriente. Es ideal para quien quiere combinar surf, ciudad y servicios cerca.",
                'difficulty' => 'intermediate',
                'latitude' => 43.3262000,
                'longitude' => -1.9737000,
                'amenities' => ['Duchas', 'Aseos', 'Aparcamiento', 'Socorristas', 'Escuela de surf', 'Alquiler de material', 'Webcam'],
            ],
            [
                'name' => 'Playa de Mundaka',
                'slug' => 'playa-de-mundaka',
                'location_slug' => 'bizkaia',
                'short_description' => 'Izquierda legendaria de rio, rapida y tubular, reservada para surfistas con experiencia.',
                'description' => "Mundaka ocupa un lugar especial en la historia del surf europeo. Su ola izquierda puede ser larga, rapida y muy tecnica cuando coinciden mar, marea y viento.\n\nNo es un spot de iniciacion. El fondo, la corriente, la precision del pico y la concentracion de surfistas hacen que sea recomendable solo para personas con nivel alto y conocimiento del entorno.",
                'difficulty' => 'advanced',
                'latitude' => 43.4077000,
                'longitude' => -2.6996000,
                'amenities' => ['Aparcamiento', 'Webcam', 'Chiringuito'],
            ],
            [
                'name' => 'Playa de Sopelana',
                'slug' => 'playa-de-sopelana',
                'location_slug' => 'bizkaia',
                'short_description' => 'Acantilados, picos consistentes y ambiente surfero cerca de Bilbao.',
                'description' => "Sopelana es una referencia para surfistas de Bizkaia por su consistencia y por la variedad de bancos que pueden aparecer. El entorno de acantilados aporta una identidad muy marcada.\n\nSuele ser una playa interesante para nivel intermedio, aunque algunos dias puede ponerse seria. Es importante observar corrientes, zonas de roca y la evolucion de la marea.",
                'difficulty' => 'intermediate',
                'latitude' => 43.3893000,
                'longitude' => -2.9946000,
                'amenities' => ['Duchas', 'Aparcamiento', 'Socorristas', 'Escuela de surf', 'Alquiler de material', 'Chiringuito'],
            ],
            [
                'name' => 'Playa de Razo',
                'slug' => 'playa-de-razo',
                'location_slug' => 'a-coruna',
                'short_description' => 'Arenal abierto de Costa da Morte con olas constantes y mucho margen para moverse.',
                'description' => "Razo es una playa amplia y muy expuesta, con un caracter atlantico claro. La longitud del arenal permite buscar diferentes zonas segun bancos, viento y marea.\n\nEs una opcion muy completa para surfistas que ya se manejan con autonomia. En dias pequenos puede ser accesible, pero con mar fuerte exige lectura de corrientes y prudencia.",
                'difficulty' => 'intermediate',
                'latitude' => 43.2941000,
                'longitude' => -8.6850000,
                'amenities' => ['Duchas', 'Aparcamiento', 'Socorristas', 'Escuela de surf', 'Alquiler de material', 'Chiringuito'],
            ],
            [
                'name' => 'Playa de Pantin',
                'slug' => 'playa-de-pantin',
                'location_slug' => 'a-coruna',
                'short_description' => 'Spot gallego reconocido por competiciones, con ola potente y mucha exposicion.',
                'description' => "Pantin es uno de los nombres clave del surf gallego. Su playa abierta recibe mar con facilidad y puede ofrecer olas de mucha calidad cuando las condiciones se ordenan.\n\nEs recomendable para surfistas con experiencia, sobre todo en dias de tamano. La energia del Atlantico, las corrientes y la variabilidad de los bancos piden entrar con criterio.",
                'difficulty' => 'advanced',
                'latitude' => 43.6266000,
                'longitude' => -8.1075000,
                'amenities' => ['Aparcamiento', 'Socorristas', 'Webcam', 'Chiringuito'],
            ],
            [
                'name' => 'Playa de Doninos',
                'slug' => 'playa-de-doninos',
                'location_slug' => 'a-coruna',
                'short_description' => 'Playa salvaje cerca de Ferrol, con picos potentes y un entorno natural muy abierto.',
                'description' => "Doninos ofrece un escenario amplio, expuesto y con mucha personalidad. Su orientacion capta mar con facilidad, lo que la convierte en una playa frecuente para sesiones con energia.\n\nPuede funcionar para niveles medios en dias controlados, pero no conviene subestimar su fuerza. Las corrientes y el tamano cambiante hacen recomendable observar antes de entrar.",
                'difficulty' => 'intermediate',
                'latitude' => 43.4956000,
                'longitude' => -8.3206000,
                'amenities' => ['Aparcamiento', 'Socorristas', 'Chiringuito'],
            ],
            [
                'name' => 'Playa de El Palmar',
                'slug' => 'playa-de-el-palmar',
                'location_slug' => 'cadiz',
                'short_description' => 'Arenal gaditano largo y accesible, muy popular para aprender y disfrutar olas suaves.',
                'description' => "El Palmar es uno de los spots mas conocidos de Cadiz por su ambiente relajado y su playa extensa. En dias pequenos y ordenados es una gran opcion para iniciarse o mejorar maniobras basicas.\n\nLa experiencia cambia bastante con viento y mareas, asi que conviene elegir bien la hora. En temporada alta puede llenarse, pero la longitud del arenal ayuda a repartir banistas y surfistas.",
                'difficulty' => 'beginner',
                'latitude' => 36.2350000,
                'longitude' => -6.0700000,
                'amenities' => ['Aparcamiento', 'Socorristas', 'Escuela de surf', 'Alquiler de material', 'Chiringuito'],
            ],
            [
                'name' => 'Playa de Los Lances',
                'slug' => 'playa-de-los-lances',
                'location_slug' => 'cadiz',
                'short_description' => 'Playa amplia de Tarifa, marcada por el viento y con sesiones variables segun el dia.',
                'description' => "Los Lances es una playa enorme y muy ligada al viento. Aunque Tarifa se asocia mas al kite y windsurf, tambien puede ofrecer sesiones de surf cuando entra mar y el viento acompana.\n\nEs una playa util para surfistas intermedios que sepan leer el parte y adaptarse. La amplitud del arenal y los servicios cercanos facilitan organizar la sesion.",
                'difficulty' => 'intermediate',
                'latitude' => 36.0314000,
                'longitude' => -5.6333000,
                'amenities' => ['Duchas', 'Aparcamiento', 'Socorristas', 'Escuela de surf', 'Alquiler de material', 'Chiringuito'],
            ],
            [
                'name' => 'Playa de Famara',
                'slug' => 'playa-de-famara',
                'location_slug' => 'las-palmas',
                'short_description' => 'Icono de Lanzarote, con mucho espacio, paisaje volcanico y ambiente de escuela.',
                'description' => "Famara combina un entorno espectacular bajo el risco con una playa amplia y muy surfera. Su espacio y oferta de escuelas la hacen especialmente atractiva para aprender o retomar confianza.\n\nAun asi, es una playa expuesta al viento y con corrientes que deben tomarse en serio. Para principiantes, lo mejor es entrar con supervision y escoger dias moderados.",
                'difficulty' => 'beginner',
                'latitude' => 29.1189000,
                'longitude' => -13.5544000,
                'amenities' => ['Aparcamiento', 'Socorristas', 'Escuela de surf', 'Alquiler de material', 'Chiringuito'],
            ],
            [
                'name' => 'Playa de Las Americas',
                'slug' => 'playa-de-las-americas',
                'location_slug' => 'santa-cruz-de-tenerife',
                'short_description' => 'Zona surfera de Tenerife con olas de roca, consistentes y tecnicas.',
                'description' => "Las Americas concentra varios picos sobre fondo volcanico en una zona muy activa del sur de Tenerife. Puede ofrecer olas de calidad y bastante consistencia durante la temporada adecuada.\n\nEl fondo de roca, la afluencia y la precision necesaria hacen que no sea el mejor lugar para iniciarse. Es un entorno mas apropiado para surfistas con experiencia y buena lectura del spot.",
                'difficulty' => 'advanced',
                'latitude' => 28.0616000,
                'longitude' => -16.7338000,
                'amenities' => ['Aseos', 'Aparcamiento', 'Escuela de surf', 'Alquiler de material', 'Webcam', 'Chiringuito'],
            ],
            [
                'name' => 'Playa de El Medano',
                'slug' => 'playa-de-el-medano',
                'location_slug' => 'santa-cruz-de-tenerife',
                'short_description' => 'Playa ventosa y abierta, conocida por deportes de agua y sesiones cambiantes.',
                'description' => "El Medano es una playa muy ligada al viento y a los deportes nauticos. Cuando las condiciones se alinean, tambien permite sesiones de surf en un entorno amplio y facil de acceder.\n\nPor su exposicion y actividad en el agua, es recomendable escoger bien la zona y el momento. Puede ser muy divertida para nivel intermedio, especialmente si se entiende el papel del viento.",
                'difficulty' => 'intermediate',
                'latitude' => 28.0450000,
                'longitude' => -16.5367000,
                'amenities' => ['Duchas', 'Aseos', 'Aparcamiento', 'Socorristas', 'Escuela de surf', 'Alquiler de material', 'Chiringuito'],
            ],
            [
                'name' => 'Playa de Mazagon',
                'slug' => 'playa-de-mazagon',
                'location_slug' => 'huelva',
                'short_description' => 'Costa atlantica onubense con arenal amplio, sesiones tranquilas y mucho espacio.',
                'description' => "Mazagon ofrece un entorno abierto y arenoso en la costa de Huelva. No tiene la consistencia de otros destinos mas expuestos, pero puede dar sesiones agradables con mar ordenado.\n\nEs una opcion tranquila para dias suaves, especialmente para surfistas que buscan espacio y poca presion en el agua. La lectura del parte es clave para no encontrar el mar demasiado plano.",
                'difficulty' => 'beginner',
                'latitude' => 37.1339000,
                'longitude' => -6.8287000,
                'amenities' => ['Duchas', 'Aseos', 'Aparcamiento', 'Socorristas', 'Chiringuito'],
            ],
        ];
    }
}
