<x-layouts::app :title="$beach->name">
    @php
        $coverUrl = $beach->coverImage?->url();
    @endphp

    <div class="flex h-full w-full max-w-none flex-1 flex-col gap-6 rounded-xl">
        <div class="flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between">
            <div>
                <h1 class="text-2xl font-semibold text-[#002833] dark:text-white">{{ $beach->name }}</h1>
            </div>

            <div class="flex flex-wrap gap-2">
                <flux:button :href="route('admin.beaches.index')" wire:navigate>
                    Volver
                </flux:button>

                @can('edit beaches')
                    <flux:button :href="route('admin.beaches.edit', $beach)" variant="primary" class="bg-[#114857] hover:bg-[#266C80]" wire:navigate>
                        Editar playa
                    </flux:button>
                @endcan
            </div>
        </div>

        <section class="overflow-hidden rounded-2xl border border-zinc-300 bg-white shadow-sm shadow-[#114857]/5 dark:border-zinc-700 dark:bg-zinc-900">
            <div class="relative h-72 bg-[#85C3D4]/10 md:h-96">
                @if ($coverUrl)
                    <img src="{{ $coverUrl }}" alt="{{ $beach->coverImage?->alt_text ?? $beach->name }}" class="h-full w-full object-cover">
                    <div class="absolute inset-0 bg-gradient-to-t from-[#002833]/70 via-[#002833]/10 to-transparent"></div>
                @else
                    <div class="grid h-full place-items-center text-[#114857] dark:text-[#85C3D4]">
                        <div class="text-center">
                            <svg class="mx-auto size-14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" aria-hidden="true">
                                <path stroke-linecap="round" stroke-linejoin="round" d="M3 17c3-4 6-4 9 0s6 4 9 0M4 13c2-2 4-2 6 0s4 2 6 0 3-2 4-1M8 7h.01M5 21h14a2 2 0 0 0 2-2V5a2 2 0 0 0-2-2H5a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2Z" />
                            </svg>
                            <p class="mt-3 text-sm font-medium">Esta playa aún no tiene portada.</p>
                        </div>
                    </div>
                @endif

                <div class="absolute bottom-5 left-5 right-5 flex flex-col gap-3 sm:flex-row sm:items-end sm:justify-between">
                    <div>
                        <div class="flex flex-wrap gap-2">
                            @if ($beach->status === 'published')
                                <span class="rounded-full bg-emerald-50 px-3 py-1 text-xs font-semibold text-emerald-700 shadow-sm">Publicada</span>
                            @elseif ($beach->status === 'archived')
                                <span class="rounded-full bg-zinc-100 px-3 py-1 text-xs font-semibold text-zinc-700 shadow-sm">Archivada</span>
                            @else
                                <span class="rounded-full bg-amber-50 px-3 py-1 text-xs font-semibold text-amber-700 shadow-sm">Borrador</span>
                            @endif

                            @if ($beach->difficulty)
                                <span class="rounded-full bg-white/90 px-3 py-1 text-xs font-semibold text-[#114857] shadow-sm">{{ ['beginner' => 'Principiante', 'intermediate' => 'Intermedia', 'advanced' => 'Avanzada'][$beach->difficulty] }}</span>
                            @endif
                        </div>
                    </div>

                    @can('delete beaches')
                        @if ($beach->status !== 'archived')
                            <form method="POST" action="{{ route('admin.beaches.destroy', $beach) }}" onsubmit="return confirm('La playa pasará a estado archivada y dejará de mostrarse como publicada. ¿Quieres continuar?')">
                                @csrf
                                @method('DELETE')
                                <button type="submit" class="inline-flex items-center gap-2 rounded-lg bg-white/90 px-4 py-2 text-sm font-semibold text-red-700 shadow-sm transition hover:bg-white hover:text-red-800">
                                    Archivar
                                </button>
                            </form>
                        @endif
                    @endcan
                </div>
            </div>
        </section>

        <div class="grid gap-6 xl:grid-cols-[380px_1fr]">
            <aside class="space-y-6">
                <section class="rounded-2xl border border-zinc-300 bg-white p-6 shadow-sm shadow-[#114857]/5 dark:border-zinc-700 dark:bg-zinc-900">
                    <h2 class="text-base font-semibold text-[#002833] dark:text-white">Resumen</h2>

                    <dl class="mt-6 space-y-4 text-sm">
                        <div>
                            <dt class="text-xs font-medium uppercase tracking-wide text-zinc-500 dark:text-zinc-400">Provincia</dt>
                            <dd class="mt-1 font-medium text-zinc-900 dark:text-white">{{ $beach->location?->name }}</dd>
                        </div>

                        <div>
                            <dt class="text-xs font-medium uppercase tracking-wide text-zinc-500 dark:text-zinc-400">Slug</dt>
                            <dd class="mt-1 break-all font-medium text-zinc-900 dark:text-white">{{ $beach->slug }}</dd>
                        </div>

                        <div class="grid grid-cols-2 gap-4">
                            <div>
                                <dt class="text-xs font-medium uppercase tracking-wide text-zinc-500 dark:text-zinc-400">Latitud</dt>
                                <dd class="mt-1 font-medium text-zinc-900 dark:text-white">{{ $beach->latitude }}</dd>
                            </div>

                            <div>
                                <dt class="text-xs font-medium uppercase tracking-wide text-zinc-500 dark:text-zinc-400">Longitud</dt>
                                <dd class="mt-1 font-medium text-zinc-900 dark:text-white">{{ $beach->longitude }}</dd>
                            </div>
                        </div>

                        <div>
                            <dt class="text-xs font-medium uppercase tracking-wide text-zinc-500 dark:text-zinc-400">Publicación</dt>
                            <dd class="mt-1 font-medium text-zinc-900 dark:text-white">{{ $beach->published_at?->format('d/m/Y H:i') ?? 'Sin publicar' }}</dd>
                        </div>

                        <div>
                            <dt class="text-xs font-medium uppercase tracking-wide text-zinc-500 dark:text-zinc-400">Creada por</dt>
                            <dd class="mt-1 font-medium text-zinc-900 dark:text-white">{{ $beach->creator?->name ?? 'No disponible' }}</dd>
                        </div>
                    </dl>
                </section>

                <section class="grid grid-cols-2 gap-3">
                    <div class="rounded-2xl border border-zinc-300 bg-white p-4 text-center shadow-sm shadow-[#114857]/5 dark:border-zinc-700 dark:bg-zinc-900">
                        <div class="text-2xl font-semibold text-[#114857] dark:text-[#85C3D4]">{{ $beach->comments_count }}</div>
                        <div class="mt-1 text-xs font-medium text-zinc-500 dark:text-zinc-400">Comentarios</div>
                    </div>

                    <div class="rounded-2xl border border-zinc-300 bg-white p-4 text-center shadow-sm shadow-[#114857]/5 dark:border-zinc-700 dark:bg-zinc-900">
                        <div class="text-2xl font-semibold text-[#114857] dark:text-[#85C3D4]">{{ $beach->favorited_by_users_count }}</div>
                        <div class="mt-1 text-xs font-medium text-zinc-500 dark:text-zinc-400">Favoritos</div>
                    </div>
                </section>
            </aside>

            <div class="space-y-6">
                <section class="rounded-2xl border border-zinc-300 bg-white p-6 shadow-sm shadow-[#114857]/5 dark:border-zinc-700 dark:bg-zinc-900">
                    <h2 class="text-base font-semibold text-[#002833] dark:text-white">Contenido editorial</h2>

                    @if ($beach->short_description)
                        <p class="mt-4 text-sm font-medium text-zinc-900 dark:text-white">{{ $beach->short_description }}</p>
                    @endif

                    <p class="mt-4 whitespace-pre-line text-sm leading-7 text-zinc-600 dark:text-zinc-300">{{ $beach->description ?: 'Esta playa aún no tiene descripción completa.' }}</p>
                </section>

                <section class="rounded-2xl border border-zinc-300 bg-white p-6 shadow-sm shadow-[#114857]/5 dark:border-zinc-700 dark:bg-zinc-900">
                    <h2 class="text-base font-semibold text-[#002833] dark:text-white">Servicios</h2>

                    <div class="mt-4 flex flex-wrap gap-2">
                        @forelse ($beach->amenities as $amenity)
                            <span class="rounded-full bg-[#85C3D4]/15 px-3 py-1 text-xs font-semibold text-[#114857] dark:bg-[#85C3D4]/10 dark:text-[#85C3D4]">{{ $amenity->name }}</span>
                        @empty
                            <span class="text-sm text-zinc-500 dark:text-zinc-400">No hay servicios asociados.</span>
                        @endforelse
                    </div>
                </section>
            </div>
        </div>
    </div>
</x-layouts::app>
