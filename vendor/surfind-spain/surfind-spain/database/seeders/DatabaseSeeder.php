<?php

namespace Database\Seeders;

use Illuminate\Database\Seeder;

class DatabaseSeeder extends Seeder
{
    /**
     * Seed the application's database.
     */
    public function run(): void
    {
        $this->call(RolesAndPermissionsSeeder::class);
        $this->call(LocationSeeder::class);
        $this->call(AmenitySeeder::class);
        $this->call(AdminUserSeeder::class);
        $this->call(BeachSeeder::class);
    }
}
