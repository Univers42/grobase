<?php

namespace Database\Seeders;

use App\Enums\Roles;
use App\Models\User;
use Illuminate\Database\Seeder;

class AdminUserSeeder extends Seeder
{
    /**
     * Run the database seeds.
     */
    public function run(): void
    {
        $admin = User::updateOrCreate(
            ['email' => 'admin@surfind.es'],
            [
                'name' => 'Admin User',
                'password' => bcrypt('admin1234'),
            ],
        );

        $admin->assignRole(Roles::ADMIN->value);
    }
}
