<x-layouts::app :title="__('Crear usuario')">
    <div class="flex h-full w-full flex-1 flex-col gap-6 rounded-xl">
        <div class="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
            <div>
                <h1 class="text-2xl font-semibold text-[#002833] dark:text-white">Crear usuario</h1>
            </div>

            <flux:button :href="route('admin.users.index')" wire:navigate>
                Volver al listado
            </flux:button>
        </div>

        <form method="POST" action="{{ route('admin.users.store') }}" class="max-w-2xl rounded-xl border border-zinc-300 bg-white p-6 shadow-sm shadow-[#114857]/5 dark:border-zinc-700 dark:bg-zinc-900">
            @csrf

            <div class="flex flex-col gap-6">
                <flux:input
                    name="name"
                    label="Nombre"
                    value="{{ old('name') }}"
                    type="text"
                    required
                    autofocus
                    autocomplete="name"
                    maxlength="255"
                    placeholder="Nombre completo"
                />

                <flux:input
                    name="email"
                    label="Email"
                    value="{{ old('email') }}"
                    type="email"
                    required
                    autocomplete="email"
                    maxlength="255"
                    placeholder="usuario@example.com"
                />

                <flux:select name="role" label="Rol" required>
                    <flux:select.option value="">Selecciona un rol</flux:select.option>
                    @foreach ($roles as $role)
                        <flux:select.option value="{{ $role->value }}" :selected="old('role') === $role->value">
                            {{ ucfirst($role->value) }}
                        </flux:select.option>
                    @endforeach
                </flux:select>

                <div class="grid gap-6 md:grid-cols-2">
                    <flux:input
                        name="password"
                        label="Contraseña"
                        type="password"
                        required
                        minlength="6"
                        autocomplete="new-password"
                        placeholder="Contraseña"
                        viewable
                    />

                    <flux:input
                        name="password_confirmation"
                        label="Confirmar contraseña"
                        type="password"
                        required
                        minlength="6"
                        autocomplete="new-password"
                        placeholder="Repite la contraseña"
                        viewable
                    />
                </div>

                <div class="flex flex-col-reverse gap-3 sm:flex-row sm:justify-end">
                    <flux:button :href="route('admin.users.index')" wire:navigate>
                        Cancelar
                    </flux:button>

                    <flux:button type="submit" variant="primary" class="bg-[#114857] hover:bg-[#266C80]">
                        Crear usuario
                    </flux:button>
                </div>
            </div>
        </form>
    </div>
</x-layouts::app>
