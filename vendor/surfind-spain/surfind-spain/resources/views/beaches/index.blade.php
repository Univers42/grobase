<x-layouts::public :title="__('Playas')">
    <section class="relative z-10 mx-auto flex max-w-7xl flex-col gap-8 px-5 pb-16 pt-8 sm:px-8 lg:px-10">
        <form method="GET" action="{{ route('beaches.index') }}" class="rounded-[2rem] bg-white/75 p-5 shadow-xl shadow-[#114857]/5 backdrop-blur">
            <div class="grid gap-4 xl:grid-cols-[1fr_220px_180px_180px_auto] xl:items-end">
                <div>
                    <label for="search" class="mb-2 block text-sm font-semibold text-[#114857]">Buscar</label>
                    <input id="search" name="search" value="{{ $search }}" placeholder="Nombre o descripción" class="block w-full rounded-2xl bg-white px-4 py-3 text-sm text-[#002833] shadow-sm outline-none transition placeholder:text-[#5097AB]/70 focus:ring-4 focus:ring-[#85C3D4]/25">
                </div>

                <div>
                    <label for="location_id" class="mb-2 block text-sm font-semibold text-[#114857]">Provincia</label>
                    <select id="location_id" name="location_id" class="block w-full rounded-2xl bg-white px-4 py-3 text-sm text-[#002833] shadow-sm outline-none transition focus:ring-4 focus:ring-[#85C3D4]/25">
                        <option value="">Todas</option>
                        @foreach ($locations as $location)
                            <option value="{{ $location->id }}" @selected((int) $locationId === $location->id)>{{ $location->name }}</option>
                        @endforeach
                    </select>
                </div>

                <div>
                    <label for="difficulty" class="mb-2 block text-sm font-semibold text-[#114857]">Dificultad</label>
                    <select id="difficulty" name="difficulty" class="block w-full rounded-2xl bg-white px-4 py-3 text-sm text-[#002833] shadow-sm outline-none transition focus:ring-4 focus:ring-[#85C3D4]/25">
                        <option value="all" @selected($difficulty === 'all')>Todas</option>
                        @foreach ($difficulties as $value => $label)
                            <option value="{{ $value }}" @selected($difficulty === $value)>{{ $label }}</option>
                        @endforeach
                    </select>
                </div>

                <div>
                    <label for="sort" class="mb-2 block text-sm font-semibold text-[#114857]">Orden</label>
                    <select id="sort" name="sort" class="block w-full rounded-2xl bg-white px-4 py-3 text-sm text-[#002833] shadow-sm outline-none transition focus:ring-4 focus:ring-[#85C3D4]/25">
                        <option value="recent" @selected($sort === 'recent')>Recientes</option>
                        <option value="comments" @selected($sort === 'comments')>Más comentadas</option>
                        <option value="favorites" @selected($sort === 'favorites')>Más guardadas</option>
                        <option value="name" @selected($sort === 'name')>Nombre A-Z</option>
                    </select>
                </div>

                <div class="flex gap-2">
                    <button type="submit" class="rounded-2xl bg-[#002833] px-5 py-3 text-sm font-bold text-white shadow-lg shadow-[#114857]/15 transition hover:-translate-y-0.5 hover:bg-[#114857]">Filtrar</button>

                    @if ($search || $locationId || $difficulty !== 'all' || $selectedAmenities !== [] || $sort !== 'recent')
                        <a href="{{ route('beaches.index') }}" class="rounded-2xl bg-white px-5 py-3 text-sm font-bold text-[#114857] shadow-sm transition hover:bg-[#DCEFF4]" wire:navigate>Limpiar</a>
                    @endif
                </div>
            </div>

            <div class="mt-5 pt-5">
                <p class="mb-3 text-sm font-semibold text-[#114857]">Servicios</p>

                <div class="flex flex-wrap gap-3">
                    @foreach ($amenities as $amenity)
                        @php
                            $isSelectedAmenity = in_array($amenity->id, $selectedAmenities, true);
                        @endphp

                        <label class="cursor-pointer">
                            <input type="checkbox" name="amenities[]" value="{{ $amenity->id }}" @checked($isSelectedAmenity) onchange="this.form.requestSubmit ? this.form.requestSubmit() : this.form.submit()" class="peer sr-only">
                            <span class="relative inline-flex items-center rounded-2xl bg-white px-4 py-2.5 text-sm font-bold text-[#114857] shadow-sm transition duration-200 hover:-translate-y-0.5 hover:bg-[#DCEFF4] peer-focus-visible:ring-4 peer-focus-visible:ring-[#85C3D4]/35 peer-checked:bg-[#002833] peer-checked:pr-8 peer-checked:text-white peer-checked:shadow-lg peer-checked:shadow-[#114857]/20 peer-checked:hover:bg-[#114857]">
                                <span>{{ $amenity->name }}</span>
                                @if ($isSelectedAmenity)
                                    <span class="pointer-events-none absolute -right-1.5 -top-1.5 flex size-5 items-center justify-center rounded-full bg-[#85C3D4] text-[13px] font-black leading-none text-[#002833] shadow-md shadow-[#114857]/20 ring-2 ring-white" aria-hidden="true">x</span>
                                @endif
                            </span>
                        </label>
                    @endforeach
                </div>
            </div>
        </form>

        @if ($beaches->isNotEmpty())
            <div class="grid gap-6 md:grid-cols-2 xl:grid-cols-3">
                @foreach ($beaches as $beach)
                    @php
                        $coverUrl = $beach->coverImage?->url();
                        $visibleAmenities = $beach->amenities->take(4);
                        $hiddenAmenities = max($beach->amenities->count() - $visibleAmenities->count(), 0);
                        $isFavorited = (bool) ($beach->is_favorited ?? false);
                    @endphp

                    <article class="group overflow-hidden rounded-[2rem] border border-[#85C3D4]/40 bg-white/80 shadow-xl shadow-[#114857]/5 backdrop-blur transition duration-300 hover:-translate-y-1 hover:shadow-2xl hover:shadow-[#114857]/12">
                        <a href="{{ route('beaches.show', $beach) }}" wire:navigate class="block">
                            <div class="relative h-56 overflow-hidden bg-[#85C3D4]/15">
                                @if ($coverUrl)
                                    <img src="{{ $coverUrl }}" alt="{{ $beach->coverImage?->alt_text ?? $beach->name }}" class="h-full w-full object-cover transition duration-500 group-hover:scale-105">
                                @else
                                    <div class="grid h-full place-items-center text-[#114857]">
                                        <svg class="size-12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" aria-hidden="true">
                                            <path stroke-linecap="round" stroke-linejoin="round" d="M3 17c3-4 6-4 9 0s6 4 9 0M4 13c2-2 4-2 6 0s4 2 6 0 3-2 4-1M8 7h.01M5 21h14a2 2 0 0 0 2-2V5a2 2 0 0 0-2-2H5a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2Z" />
                                        </svg>
                                    </div>
                                @endif

                                <div class="absolute left-4 top-4 flex flex-wrap gap-2">
                                    @if ($beach->difficulty)
                                        <span class="rounded-full bg-white/90 px-3 py-1 text-xs font-bold text-[#114857] shadow-sm backdrop-blur">{{ $difficulties[$beach->difficulty] }}</span>
                                    @endif
                                    <span class="rounded-full bg-[#002833]/85 px-3 py-1 text-xs font-bold text-white shadow-sm backdrop-blur">{{ $beach->location?->name }}</span>
                                </div>
                            </div>
                        </a>

                        <div class="p-5">
                            <div class="flex items-start justify-between gap-4">
                                <a href="{{ route('beaches.show', $beach) }}" wire:navigate class="group/title min-w-0 flex-1">
                                    <h2 class="text-xl font-black text-[#002833] transition group-hover/title:text-[#266C80]">{{ $beach->name }}</h2>
                                </a>

                                @auth
                                    <form method="POST" action="{{ $isFavorited ? route('beaches.favorites.destroy', $beach) : route('beaches.favorites.store', $beach) }}" class="shrink-0">
                                        @csrf

                                        @if ($isFavorited)
                                            @method('DELETE')
                                        @endif

                                        <button type="submit" aria-label="{{ $isFavorited ? 'Quitar de guardadas' : 'Guardar playa' }}" class="group inline-flex items-center gap-1.5 rounded-full border border-[#85C3D4]/45 bg-white px-3 py-1.5 text-sm font-black text-[#002833] shadow-sm shadow-[#114857]/5 transition hover:-translate-y-0.5 hover:border-[#002833]/20 hover:bg-[#DCEFF4] focus:outline-none focus:ring-4 focus:ring-[#85C3D4]/30">
                                            <svg class="size-4 transition group-hover:scale-110 {{ $isFavorited ? 'text-rose-500' : 'text-[#002833]' }}" viewBox="0 0 24 24" fill="{{ $isFavorited ? 'currentColor' : 'none' }}" stroke="currentColor" stroke-width="2" aria-hidden="true">
                                                <path stroke-linecap="round" stroke-linejoin="round" d="M21 8.25c0-2.485-2.099-4.5-4.688-4.5-1.935 0-3.597 1.126-4.312 2.733C11.285 4.876 9.623 3.75 7.688 3.75 5.098 3.75 3 5.765 3 8.25c0 7.22 9 12 9 12s9-4.78 9-12Z" />
                                            </svg>
                                            <span>{{ $beach->favorited_by_users_count }}</span>
                                        </button>
                                    </form>
                                @else
                                    <a href="{{ route('login') }}" aria-label="Guardar playa" class="group inline-flex shrink-0 items-center gap-1.5 rounded-full border border-[#85C3D4]/45 bg-white px-3 py-1.5 text-sm font-black text-[#002833] shadow-sm shadow-[#114857]/5 transition hover:-translate-y-0.5 hover:border-[#002833]/20 hover:bg-[#DCEFF4] focus:outline-none focus:ring-4 focus:ring-[#85C3D4]/30">
                                        <svg class="size-4 transition group-hover:scale-110" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true">
                                            <path stroke-linecap="round" stroke-linejoin="round" d="M21 8.25c0-2.485-2.099-4.5-4.688-4.5-1.935 0-3.597 1.126-4.312 2.733C11.285 4.876 9.623 3.75 7.688 3.75 5.098 3.75 3 5.765 3 8.25c0 7.22 9 12 9 12s9-4.78 9-12Z" />
                                        </svg>
                                        <span>{{ $beach->favorited_by_users_count }}</span>
                                    </a>
                                @endauth
                            </div>

                            <p class="mt-3 line-clamp-3 min-h-[4.5rem] text-sm leading-6 text-[#266C80]">{{ $beach->short_description ?? 'Playa publicada en Surfind Spain pendiente de completar con más detalles.' }}</p>

                            <div class="mt-4 flex min-h-8 flex-wrap gap-2">
                                @forelse ($visibleAmenities as $amenity)
                                    <span class="rounded-full bg-[#85C3D4]/18 px-3 py-1 text-xs font-semibold text-[#114857]">{{ $amenity->name }}</span>
                                @empty
                                    <span class="text-xs font-semibold text-[#5097AB]">Sin servicios indicados</span>
                                @endforelse

                                @if ($hiddenAmenities > 0)
                                    <span class="rounded-full bg-white px-3 py-1 text-xs font-semibold text-[#114857] ring-1 ring-[#85C3D4]/45">+{{ $hiddenAmenities }}</span>
                                @endif
                            </div>

                            <div class="mt-5 flex items-center justify-between border-t border-[#85C3D4]/25 pt-4 text-sm font-semibold text-[#266C80]">
                                <div class="flex items-center gap-3">
                                    <span>{{ $beach->published_comments_count }} comentarios</span>
                                </div>

                                <a href="{{ route('beaches.show', $beach) }}" wire:navigate class="text-[#002833] transition hover:text-[#266C80]">Ver playa</a>
                            </div>
                        </div>
                    </article>
                @endforeach
            </div>

            @if ($beaches->hasPages())
                <div class="rounded-[2rem] border border-[#85C3D4]/35 bg-white/70 px-5 py-4 shadow-sm shadow-[#114857]/5 backdrop-blur">
                    {{ $beaches->links() }}
                </div>
            @endif
        @else
            <div class="rounded-[2rem] border border-[#85C3D4]/45 bg-white/75 px-6 py-14 text-center shadow-xl shadow-[#114857]/5 backdrop-blur">
                <h2 class="text-2xl font-black text-[#002833]">No hay playas con estos filtros</h2>
                <p class="mx-auto mt-3 max-w-xl text-sm leading-6 text-[#266C80]">Prueba a cambiar la provincia, dificultad o servicios seleccionados para ampliar los resultados.</p>
                <a href="{{ route('beaches.index') }}" class="mt-6 inline-flex rounded-full bg-[#002833] px-5 py-3 text-sm font-bold text-white transition hover:bg-[#114857]" wire:navigate>Limpiar filtros</a>
            </div>
        @endif
    </section>
</x-layouts::public>
