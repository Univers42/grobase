<x-layouts::app :title="__('Playas')">
    <div class="flex h-full w-full max-w-none flex-1 flex-col gap-6 rounded-xl">
        <div class="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
            <div>
                <h1 class="text-2xl font-semibold text-[#002833] dark:text-white">Playas</h1>
            </div>

            @can('create beaches')
                <flux:button :href="route('admin.beaches.create')" variant="primary" class="bg-[#114857] hover:bg-[#266C80]" wire:navigate>
                    Crear playa
                </flux:button>
            @endcan
        </div>

        <form method="GET" action="{{ route('admin.beaches.index') }}" class="w-full rounded-xl border border-zinc-300 bg-white p-4 shadow-sm shadow-[#114857]/5 dark:border-zinc-700 dark:bg-zinc-900">
            <div class="grid gap-4 xl:grid-cols-[1fr_220px_180px_180px_auto] xl:items-end">
                <flux:input name="search" label="Buscar playa" placeholder="Nombre o descripción" value="{{ $search }}" />

                <flux:select name="location_id" label="Provincia">
                    <flux:select.option value="">Todas</flux:select.option>
                    @foreach ($locations as $location)
                        <flux:select.option value="{{ $location->id }}" :selected="(int) $locationId === $location->id">{{ $location->name }}</flux:select.option>
                    @endforeach
                </flux:select>

                <flux:select name="status" label="Estado">
                    <flux:select.option value="all" :selected="$status === 'all'">Todos</flux:select.option>
                    @foreach ($statuses as $value => $label)
                        <flux:select.option value="{{ $value }}" :selected="$status === $value">{{ $label }}</flux:select.option>
                    @endforeach
                </flux:select>

                <flux:select name="difficulty" label="Dificultad">
                    <flux:select.option value="all" :selected="$difficulty === 'all'">Todas</flux:select.option>
                    @foreach ($difficulties as $value => $label)
                        <flux:select.option value="{{ $value }}" :selected="$difficulty === $value">{{ $label }}</flux:select.option>
                    @endforeach
                </flux:select>

                <div class="flex gap-2">
                    <flux:button type="submit" variant="primary" class="bg-[#114857] hover:bg-[#266C80]">Filtrar</flux:button>

                    @if ($search || $locationId || $status !== 'all' || $difficulty !== 'all')
                        <flux:button :href="route('admin.beaches.index')" wire:navigate>Limpiar</flux:button>
                    @endif
                </div>
            </div>
        </form>

        <div class="w-full overflow-hidden rounded-xl border border-zinc-300 bg-white shadow-sm shadow-[#114857]/5 dark:border-zinc-700 dark:bg-zinc-900">
            <div class="overflow-x-auto">
                <table class="w-full table-fixed divide-y divide-zinc-200 text-sm dark:divide-white/10">
                    <thead class="bg-[#85C3D4]/10 text-left text-xs font-semibold uppercase tracking-wide text-[#114857] dark:bg-[#85C3D4]/10 dark:text-[#85C3D4]">
                        <tr>
                            <th class="w-[30%] px-4 py-3">Playa</th>
                            <th class="w-[15%] px-4 py-3">Provincia</th>
                            <th class="w-[12%] px-4 py-3">Estado</th>
                            <th class="w-[12%] px-4 py-3">Dificultad</th>
                            <th class="w-[13%] px-4 py-3">Publicación</th>
                            <th class="w-[10%] px-4 py-3">Actividad</th>
                            <th class="w-[8%] px-4 py-3">Acciones</th>
                        </tr>
                    </thead>

                    <tbody class="divide-y divide-zinc-200 dark:divide-white/10">
                        @forelse ($beaches as $beach)
                            @php
                                $coverUrl = $beach->coverImage?->url();
                            @endphp

                            <tr class="text-zinc-700 transition hover:bg-[#85C3D4]/5 dark:text-zinc-300 dark:hover:bg-[#85C3D4]/5">
                                <td class="px-4 py-4">
                                    <div class="flex min-w-0 items-center gap-3">
                                        @if ($coverUrl)
                                            <img src="{{ $coverUrl }}" alt="{{ $beach->coverImage?->alt_text ?? $beach->name }}" class="size-14 rounded-xl object-cover">
                                        @else
                                            <div class="grid size-14 place-items-center rounded-xl bg-[#85C3D4]/15 text-[#114857] dark:text-[#85C3D4]">
                                                <svg class="size-6" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" aria-hidden="true">
                                                    <path stroke-linecap="round" stroke-linejoin="round" d="M3 17c3-4 6-4 9 0s6 4 9 0M4 13c2-2 4-2 6 0s4 2 6 0 3-2 4-1M8 7h.01M5 21h14a2 2 0 0 0 2-2V5a2 2 0 0 0-2-2H5a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2Z" />
                                                </svg>
                                            </div>
                                        @endif

                                        <div class="min-w-0">
                                            <div class="truncate font-medium text-zinc-900 dark:text-white">{{ $beach->name }}</div>
                                            <div class="mt-1 truncate text-xs text-zinc-500 dark:text-zinc-400">{{ $beach->short_description ?? $beach->slug }}</div>
                                        </div>
                                    </div>
                                </td>
                                <td class="truncate px-4 py-4">{{ $beach->location?->name }}</td>
                                <td class="px-4 py-4">
                                    @if ($beach->status === 'published')
                                        <span class="rounded-full bg-emerald-50 px-2.5 py-1 text-xs font-semibold text-emerald-700 dark:bg-emerald-500/10 dark:text-emerald-200">Publicada</span>
                                    @elseif ($beach->status === 'archived')
                                        <span class="rounded-full bg-zinc-100 px-2.5 py-1 text-xs font-semibold text-zinc-700 dark:bg-white/10 dark:text-zinc-200">Archivada</span>
                                    @else
                                        <span class="rounded-full bg-amber-50 px-2.5 py-1 text-xs font-semibold text-amber-700 dark:bg-amber-500/10 dark:text-amber-200">Borrador</span>
                                    @endif
                                </td>
                                <td class="px-4 py-4 text-zinc-500 dark:text-zinc-400">{{ $difficulties[$beach->difficulty] ?? '-' }}</td>
                                <td class="whitespace-nowrap px-4 py-4 text-zinc-500 dark:text-zinc-400">{{ $beach->published_at?->format('d/m/Y') ?? '-' }}</td>
                                <td class="px-4 py-4 text-xs text-zinc-500 dark:text-zinc-400">
                                    <span title="Comentarios">{{ $beach->comments_count }} com.</span>
                                    <span class="mx-1 text-zinc-300">/</span>
                                    <span title="Favoritos">{{ $beach->favorited_by_users_count }} fav.</span>
                                </td>
                                <td class="px-4 py-4">
                                    <div class="flex justify-start gap-1.5">
                                        <a href="{{ route('admin.beaches.show', $beach) }}" title="Ver" aria-label="Ver playa" wire:navigate class="inline-flex size-8 items-center justify-center text-zinc-500 transition hover:text-zinc-900 dark:text-zinc-400 dark:hover:text-white">
                                            <svg class="size-5" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" aria-hidden="true">
                                                <path stroke-linecap="round" stroke-linejoin="round" d="M2.25 12s3.75-6.75 9.75-6.75S21.75 12 21.75 12 18 18.75 12 18.75 2.25 12 2.25 12Z" />
                                                <path stroke-linecap="round" stroke-linejoin="round" d="M14.25 12a2.25 2.25 0 1 1-4.5 0 2.25 2.25 0 0 1 4.5 0Z" />
                                            </svg>
                                        </a>

                                        @can('edit beaches')
                                            <a href="{{ route('admin.beaches.edit', $beach) }}" title="Editar" aria-label="Editar playa" wire:navigate class="inline-flex size-8 items-center justify-center text-[#114857] transition hover:text-[#266C80] dark:text-[#85C3D4] dark:hover:text-white">
                                                <svg class="size-5" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" aria-hidden="true">
                                                    <path stroke-linecap="round" stroke-linejoin="round" d="m16.862 4.487 1.687-1.688a1.875 1.875 0 1 1 2.652 2.652L9.75 16.902 6 18l1.098-3.75L16.862 4.487Z" />
                                                    <path stroke-linecap="round" stroke-linejoin="round" d="M19.5 13.5V19A2.5 2.5 0 0 1 17 21.5H5A2.5 2.5 0 0 1 2.5 19V7A2.5 2.5 0 0 1 5 4.5h5.5" />
                                                </svg>
                                            </a>
                                        @endcan

                                        @can('delete beaches')
                                            @if ($beach->status !== 'archived')
                                                <form method="POST" action="{{ route('admin.beaches.destroy', $beach) }}" onsubmit="return confirm('La playa pasará a estado archivada. ¿Quieres continuar?')">
                                                    @csrf
                                                    @method('DELETE')
                                                    <button type="submit" title="Archivar" aria-label="Archivar playa" class="inline-flex size-8 items-center justify-center text-red-600 transition hover:text-red-700 dark:text-red-300 dark:hover:text-red-200">
                                                        <svg class="size-5" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" aria-hidden="true">
                                                            <path stroke-linecap="round" stroke-linejoin="round" d="M20.25 7.5 19.2 19.2a2.25 2.25 0 0 1-2.24 2.05H7.04a2.25 2.25 0 0 1-2.24-2.05L3.75 7.5M9.75 11.25v6M14.25 11.25v6M2.25 7.5h19.5M9 7.5V4.875A1.875 1.875 0 0 1 10.875 3h2.25A1.875 1.875 0 0 1 15 4.875V7.5" />
                                                        </svg>
                                                    </button>
                                                </form>
                                            @endif
                                        @endcan
                                    </div>
                                </td>
                            </tr>
                        @empty
                            <tr>
                                <td colspan="7" class="px-4 py-10 text-center text-sm text-zinc-500 dark:text-zinc-400">
                                    No hay playas que coincidan con los filtros actuales.
                                </td>
                            </tr>
                        @endforelse
                    </tbody>
                </table>
            </div>

            @if ($beaches->hasPages())
                <div class="border-t border-zinc-200 px-4 py-3 dark:border-white/10">
                    {{ $beaches->links() }}
                </div>
            @endif
        </div>
    </div>
</x-layouts::app>
