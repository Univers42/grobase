<x-layouts::app :title="__('Usuarios')">
    <div class="flex h-full w-full max-w-none flex-1 flex-col gap-6 rounded-xl">
        <div class="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
            <div>
                <h1 class="text-2xl font-semibold text-[#002833] dark:text-white">Usuarios</h1>
            </div>

            @can('manage users')
                <flux:button :href="route('admin.users.create')" variant="primary" class="bg-[#114857] hover:bg-[#266C80]" wire:navigate>
                    Crear usuario
                </flux:button>
            @endcan
        </div>

        <form method="GET" action="{{ route('admin.users.index') }}" class="w-full rounded-xl border border-zinc-300 bg-white p-4 shadow-sm shadow-[#114857]/5 dark:border-zinc-700 dark:bg-zinc-900">
            <div class="grid gap-4 md:grid-cols-[1fr_220px_auto] md:items-end">
                <flux:input
                    name="search"
                    label="Buscar usuario"
                    placeholder="Nombre o email"
                    value="{{ $search }}"
                />

                <flux:select name="status" label="Estado">
                    <flux:select.option value="all" :selected="$status === 'all'">Todos</flux:select.option>
                    <flux:select.option value="active" :selected="$status === 'active'">Activos</flux:select.option>
                    <flux:select.option value="disabled" :selected="$status === 'disabled'">Deshabilitados</flux:select.option>
                </flux:select>

                <div class="flex gap-2">
                    <flux:button type="submit" variant="primary" class="bg-[#114857] hover:bg-[#266C80]">Filtrar</flux:button>

                    @if ($search || $status !== 'all')
                        <flux:button :href="route('admin.users.index')" wire:navigate>Limpiar</flux:button>
                    @endif
                </div>
            </div>
        </form>

        <div class="w-full overflow-hidden rounded-xl border border-zinc-300 bg-white shadow-sm shadow-[#114857]/5 dark:border-zinc-700 dark:bg-zinc-900">
            <div class="overflow-x-auto">
                <table class="w-full table-fixed divide-y divide-zinc-200 text-sm dark:divide-white/10">
                    <thead class="bg-[#85C3D4]/10 text-left text-xs font-semibold uppercase tracking-wide text-[#114857] dark:bg-[#85C3D4]/10 dark:text-[#85C3D4]">
                        <tr>
                            <th class="w-[22%] px-4 py-3">Nombre</th>
                            <th class="w-[25%] px-4 py-3">Correo</th>
                            <th class="w-[14%] px-4 py-3">Rol</th>
                            <th class="w-[13%] px-4 py-3">Estado</th>
                            <th class="w-[9%] px-4 py-3">Alta</th>
                            <th class="w-[9%] px-4 py-3">Deshabilitado</th>
                            <th class="w-[8%] px-4 py-3">Acciones</th>
                        </tr>
                    </thead>

                    <tbody class="divide-y divide-zinc-200 dark:divide-white/10">
                        @forelse ($users as $user)
                            <tr class="text-zinc-700 transition hover:bg-[#85C3D4]/5 dark:text-zinc-300 dark:hover:bg-[#85C3D4]/5">
                                <td class="truncate px-4 py-4 font-medium text-zinc-900 dark:text-white">
                                    {{ $user->name }}
                                </td>
                                <td class="truncate px-4 py-4 text-zinc-500 dark:text-zinc-400">
                                    {{ $user->email }}
                                </td>
                                <td class="px-4 py-4">
                                    <div class="flex flex-wrap gap-1.5">
                                        @forelse ($user->roles as $role)
                                            <span class="rounded-full bg-[#85C3D4]/15 px-2 py-1 text-xs font-medium text-[#114857] dark:bg-[#85C3D4]/10 dark:text-[#85C3D4]">{{ $role->name }}</span>
                                        @empty
                                            <span class="text-xs text-zinc-500 dark:text-zinc-400">Sin rol</span>
                                        @endforelse
                                    </div>
                                </td>
                                <td class="px-4 py-4">
                                    @if ($user->trashed())
                                        <span class="rounded-full bg-red-50 px-2.5 py-1 text-xs font-semibold text-red-700 dark:bg-red-500/10 dark:text-red-200">Deshabilitado</span>
                                    @else
                                        <span class="rounded-full bg-emerald-50 px-2.5 py-1 text-xs font-semibold text-emerald-700 dark:bg-emerald-500/10 dark:text-emerald-200">Activo</span>
                                    @endif
                                </td>
                                <td class="whitespace-nowrap px-4 py-4 text-zinc-500 dark:text-zinc-400">{{ $user->created_at?->format('d/m/Y') }}</td>
                                <td class="whitespace-nowrap px-4 py-4 text-zinc-500 dark:text-zinc-400">{{ $user->deleted_at?->format('d/m/Y') ?? '-' }}</td>
                                <td class="px-4 py-4">
                                    <div class="flex justify-start gap-1.5">
                                        @if ($user->trashed())
                                            <form method="POST" action="{{ route('admin.users.restore', $user->id) }}">
                                                @csrf
                                                @method('PATCH')
                                                <button type="submit" title="Reactivar" aria-label="Reactivar usuario" class="inline-flex size-8 items-center justify-center text-emerald-600 transition hover:text-emerald-700 dark:text-emerald-300 dark:hover:text-emerald-200">
                                                    <svg class="size-5" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" aria-hidden="true">
                                                        <path stroke-linecap="round" stroke-linejoin="round" d="M16.02 7.98A5.625 5.625 0 1 0 17.625 12H21m0 0-3-3m3 3-3 3" />
                                                    </svg>
                                                </button>
                                            </form>
                                        @else
                                            <a href="{{ route('admin.users.show', $user) }}" title="Ver" aria-label="Ver usuario" wire:navigate class="inline-flex size-8 items-center justify-center text-zinc-500 transition hover:text-zinc-900 dark:text-zinc-400 dark:hover:text-white">
                                                <svg class="size-5" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" aria-hidden="true">
                                                    <path stroke-linecap="round" stroke-linejoin="round" d="M2.25 12s3.75-6.75 9.75-6.75S21.75 12 21.75 12 18 18.75 12 18.75 2.25 12 2.25 12Z" />
                                                    <path stroke-linecap="round" stroke-linejoin="round" d="M14.25 12a2.25 2.25 0 1 1-4.5 0 2.25 2.25 0 0 1 4.5 0Z" />
                                                </svg>
                                            </a>

                                            @if (auth()->id() !== $user->id)
                                                <form method="POST" action="{{ route('admin.users.destroy', $user) }}" onsubmit="return confirm('Esta cuenta quedará deshabilitada y no podrá iniciar sesión. ¿Quieres continuar?')">
                                                    @csrf
                                                    @method('DELETE')
                                                    <button type="submit" title="Deshabilitar" aria-label="Deshabilitar usuario" class="inline-flex size-8 items-center justify-center text-red-600 transition hover:text-red-700 dark:text-red-300 dark:hover:text-red-200">
                                                        <svg class="size-5" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" aria-hidden="true">
                                                            <path stroke-linecap="round" stroke-linejoin="round" d="M18.364 5.636A9 9 0 1 0 5.636 18.364 9 9 0 0 0 18.364 5.636ZM6.75 6.75l10.5 10.5" />
                                                        </svg>
                                                    </button>
                                                </form>
                                            @endif
                                        @endif
                                    </div>
                                </td>
                            </tr>
                        @empty
                            <tr>
                                <td colspan="7" class="px-4 py-10 text-center text-sm text-zinc-500 dark:text-zinc-400">
                                    No hay usuarios que coincidan con los filtros actuales.
                                </td>
                            </tr>
                        @endforelse
                    </tbody>
                </table>
            </div>

            @if ($users->hasPages())
                <div class="border-t border-zinc-200 px-4 py-3 dark:border-white/10">
                    {{ $users->links() }}
                </div>
            @endif
        </div>
    </div>
</x-layouts::app>
