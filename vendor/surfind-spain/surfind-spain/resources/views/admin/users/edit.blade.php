<x-layouts::app :title="__('Editar usuario')">
    <div class="flex h-full w-full max-w-none flex-1 flex-col gap-6 rounded-xl">
        <div class="flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between">
            <div>
                <h1 class="text-2xl font-semibold text-[#002833] dark:text-white">Editar {{ $user->name }}</h1>
            </div>

            <div class="flex flex-wrap gap-2">
                <flux:button :href="route('admin.users.show', $user)" wire:navigate>
                    Ver ficha
                </flux:button>

                <flux:button :href="route('admin.users.index')" wire:navigate>
                    Volver al listado
                </flux:button>
            </div>
        </div>

        <div class="grid gap-6 xl:grid-cols-[1fr_340px]">
            <form method="POST" action="{{ route('admin.users.update', $user) }}" class="rounded-2xl border border-zinc-300 bg-white p-6 shadow-sm shadow-[#114857]/5 dark:border-zinc-700 dark:bg-zinc-900">
                @csrf
                @method('PUT')

                <div class="space-y-8">
                    <section>
                        <div class="mb-5">
                            <h2 class="text-base font-semibold text-[#002833] dark:text-white">Datos principales</h2>
                        </div>

                        <div class="grid gap-6 lg:grid-cols-2">
                            <flux:input
                                name="name"
                                label="Nombre"
                                value="{{ old('name', $user->name) }}"
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
                                value="{{ old('email', $user->email) }}"
                                type="email"
                                required
                                autocomplete="email"
                                maxlength="255"
                                placeholder="usuario@example.com"
                            />
                        </div>

                        <div class="mt-6 max-w-sm">
                            <flux:select name="role" label="Rol" required>
                                @foreach ($roles as $role)
                                    <flux:select.option value="{{ $role->value }}" :selected="old('role', $user->roles->first()?->name) === $role->value">
                                        {{ ucfirst($role->value) }}
                                    </flux:select.option>
                                @endforeach
                            </flux:select>
                        </div>
                    </section>

                    <section class="border-t border-zinc-300 pt-8 dark:border-zinc-700">
                        <div class="mb-5">
                            <h2 class="text-base font-semibold text-[#002833] dark:text-white">Cambiar contraseña</h2>
                            <p class="mt-1 text-sm text-zinc-500 dark:text-zinc-400">Deja estos campos vacios si no quieres modificar la contraseña actual</p>
                        </div>

                        <div class="grid gap-6 lg:grid-cols-2">
                            <flux:input
                                name="password"
                                label="Nueva contraseña"
                                type="password"
                                minlength="6"
                                autocomplete="new-password"
                                placeholder="Nueva contraseña"
                                viewable
                            />

                            <flux:input
                                name="password_confirmation"
                                label="Confirmar contraseña"
                                type="password"
                                minlength="6"
                                autocomplete="new-password"
                                placeholder="Repite la nueva contraseña"
                                viewable
                            />
                        </div>
                    </section>

                    <div class="flex flex-col-reverse gap-3 border-t border-zinc-300 pt-6 dark:border-zinc-700 sm:flex-row sm:justify-end">
                        <flux:button :href="route('admin.users.show', $user)" wire:navigate>
                            Cancelar
                        </flux:button>

                        <flux:button type="submit" variant="primary" class="bg-[#114857] hover:bg-[#266C80]">
                            Guardar cambios
                        </flux:button>
                    </div>
                </div>
            </form>

            <aside class="space-y-4">
                <section class="rounded-2xl border border-zinc-300 bg-white p-5 shadow-sm shadow-[#114857]/5 dark:border-zinc-700 dark:bg-zinc-900">
                    <h2 class="text-sm font-semibold text-[#002833] dark:text-white">Estado de la cuenta</h2>

                    <div class="mt-4 space-y-3 text-sm">
                        <div class="flex items-center justify-between gap-3">
                            <span class="text-zinc-500 dark:text-zinc-400">Acceso</span>
                            @if ($user->trashed())
                                <span class="rounded-full bg-red-50 px-2.5 py-1 text-xs font-semibold text-red-700 dark:bg-red-500/10 dark:text-red-200">Deshabilitado</span>
                            @else
                                <span class="rounded-full bg-emerald-50 px-2.5 py-1 text-xs font-semibold text-emerald-700 dark:bg-emerald-500/10 dark:text-emerald-200">Activo</span>
                            @endif
                        </div>

                        <div class="flex items-center justify-between gap-3">
                            <span class="text-zinc-500 dark:text-zinc-400">Alta</span>
                            <span class="font-medium text-zinc-900 dark:text-white">{{ $user->created_at?->format('d/m/Y') }}</span>
                        </div>

                        <div class="flex items-center justify-between gap-3">
                            <span class="text-zinc-500 dark:text-zinc-400">Email verificado</span>
                            <span class="font-medium text-zinc-900 dark:text-white">{{ $user->email_verified_at?->format('d/m/Y') ?? 'No' }}</span>
                        </div>
                    </div>
                </section>
            </aside>
        </div>
    </div>
</x-layouts::app>
