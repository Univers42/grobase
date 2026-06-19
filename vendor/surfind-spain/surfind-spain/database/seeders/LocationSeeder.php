<?php

namespace Database\Seeders;

use App\Models\Location;
use Illuminate\Database\Seeder;
use Illuminate\Support\Str;

class LocationSeeder extends Seeder
{
    /**
     * Run the database seeds.
     */
    public function run(): void
    {
        $provinces = [
            'A Coruna',
            'Alicante',
            'Almeria',
            'Asturias',
            'Barcelona',
            'Bizkaia',
            'Cadiz',
            'Cantabria',
            'Castellon',
            'Ceuta',
            'Gipuzkoa',
            'Girona',
            'Granada',
            'Huelva',
            'Illes Balears',
            'Las Palmas',
            'Lugo',
            'Malaga',
            'Melilla',
            'Murcia',
            'Pontevedra',
            'Santa Cruz de Tenerife',
            'Tarragona',
            'Valencia',
        ];

        foreach ($provinces as $province) {
            Location::updateOrCreate(
                ['slug' => Str::slug($province)],
                ['name' => $province],
            );
        }
    }
}
