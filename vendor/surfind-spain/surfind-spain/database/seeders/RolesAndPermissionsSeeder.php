<?php

namespace Database\Seeders;

use App\Enums\Permissions;
use App\Enums\Roles;
use Illuminate\Database\Seeder;
use Spatie\Permission\Models\Permission;
use Spatie\Permission\Models\Role;
use Spatie\Permission\PermissionRegistrar;

class RolesAndPermissionsSeeder extends Seeder
{
    /**
     * Run the database seeds.
     */
    public function run(): void
    {
        app()[PermissionRegistrar::class]->forgetCachedPermissions();

        foreach (Permissions::cases() as $permission) {
            Permission::firstOrCreate([
                'name' => $permission->value,
                'guard_name' => 'web',
            ]);
        }

        $userRole = Role::firstOrCreate([
            'name' => Roles::USER->value,
            'guard_name' => 'web',
        ]);

        $userRole->syncPermissions([
            Permissions::VIEW_BEACHES->value,
            Permissions::CREATE_REVIEWS->value,
            Permissions::EDIT_OWN_REVIEWS->value,
            Permissions::DELETE_OWN_REVIEWS->value,
        ]);

        $adminRole = Role::firstOrCreate([
            'name' => Roles::ADMIN->value,
            'guard_name' => 'web',
        ]);

        $adminRole->syncPermissions(Permission::all());
    }
}
