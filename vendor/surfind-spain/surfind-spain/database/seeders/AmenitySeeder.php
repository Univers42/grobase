<?php

namespace Database\Seeders;

use App\Models\Amenity;
use Illuminate\Database\Seeder;

class AmenitySeeder extends Seeder
{
    /**
     * Run the database seeds.
     */
    public function run(): void
    {
        $amenities = [
            ['name' => 'Duchas', 'icon' => 'shower'],
            ['name' => 'Aseos', 'icon' => 'toilet'],
            ['name' => 'Aparcamiento', 'icon' => 'parking'],
            ['name' => 'Socorristas', 'icon' => 'lifebuoy'],
            ['name' => 'Escuela de surf', 'icon' => 'surf-school'],
            ['name' => 'Alquiler de material', 'icon' => 'rental'],
            ['name' => 'Webcam', 'icon' => 'webcam'],
            ['name' => 'Chiringuito', 'icon' => 'beach-bar'],
        ];

        foreach ($amenities as $amenity) {
            Amenity::updateOrCreate(
                ['name' => $amenity['name']],
                ['icon' => $amenity['icon']],
            );
        }
    }
}
