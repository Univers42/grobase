<x-layouts::public :title="$beach->name">
    @php
        $coverUrl = $beach->coverImage?->url();
    @endphp

    <article class="relative z-10 mx-auto max-w-7xl px-5 pb-16 pt-8 sm:px-8 lg:px-10">
        <div class="mb-6">
            <a href="{{ route('beaches.index') }}" class="inline-flex items-center gap-2 rounded-full border border-[#85C3D4]/45 bg-white/65 px-4 py-2 text-sm font-bold text-[#114857] shadow-sm shadow-[#5097AB]/10 transition hover:bg-white hover:text-[#002833]" wire:navigate>
                <svg class="size-4" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true">
                    <path stroke-linecap="round" stroke-linejoin="round" d="M10.5 19.5 3 12m0 0 7.5-7.5M3 12h18" />
                </svg>
                Volver a playas
            </a>
        </div>

        <section class="overflow-hidden rounded-[2.5rem] border border-[#85C3D4]/45 bg-white/70 shadow-2xl shadow-[#114857]/10 backdrop-blur">
            <div class="relative h-[22rem] bg-[#85C3D4]/15 md:h-[32rem]">
                @if ($coverUrl)
                    <img src="{{ $coverUrl }}" alt="{{ $beach->coverImage?->alt_text ?? $beach->name }}" class="h-full w-full object-cover">
                    <div class="absolute inset-0 bg-gradient-to-t from-[#002833]/80 via-[#002833]/25 to-transparent"></div>
                @else
                    <div class="grid h-full place-items-center text-[#114857]">
                        <div class="text-center">
                            <svg class="mx-auto size-16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" aria-hidden="true">
                                <path stroke-linecap="round" stroke-linejoin="round" d="M3 17c3-4 6-4 9 0s6 4 9 0M4 13c2-2 4-2 6 0s4 2 6 0 3-2 4-1M8 7h.01M5 21h14a2 2 0 0 0 2-2V5a2 2 0 0 0-2-2H5a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2Z" />
                            </svg>
                            <p class="mt-3 text-sm font-bold">Sin portada disponible</p>
                        </div>
                    </div>
                @endif

                <div class="absolute right-5 top-5 z-10 md:right-7 md:top-7">
                    @auth
                        <form method="POST" action="{{ $isFavorited ? route('beaches.favorites.destroy', $beach) : route('beaches.favorites.store', $beach) }}">
                            @csrf

                            @if ($isFavorited)
                                @method('DELETE')
                            @endif

                            <button type="submit" aria-label="{{ $isFavorited ? 'Quitar de guardadas' : 'Guardar playa' }}" class="group inline-flex items-center gap-2 rounded-full border border-white/80 bg-white/90 px-4 py-2.5 text-sm font-black text-[#002833] shadow-xl shadow-[#002833]/20 backdrop-blur transition hover:-translate-y-0.5 hover:bg-white focus:outline-none focus:ring-4 focus:ring-white/40">
                                <svg class="size-5 transition group-hover:scale-110 {{ $isFavorited ? 'text-rose-500' : 'text-[#002833]' }}" viewBox="0 0 24 24" fill="{{ $isFavorited ? 'currentColor' : 'none' }}" stroke="currentColor" stroke-width="1.9" aria-hidden="true">
                                    <path stroke-linecap="round" stroke-linejoin="round" d="M21 8.25c0-2.485-2.099-4.5-4.688-4.5-1.935 0-3.597 1.126-4.312 2.733C11.285 4.876 9.623 3.75 7.688 3.75 5.098 3.75 3 5.765 3 8.25c0 7.22 9 12 9 12s9-4.78 9-12Z" />
                                </svg>
                                <span>{{ $beach->favorited_by_users_count }}</span>
                            </button>
                        </form>
                    @else
                        <a href="{{ route('login') }}" aria-label="Guardar playa" class="group inline-flex items-center gap-2 rounded-full border border-white/80 bg-white/90 px-4 py-2.5 text-sm font-black text-[#002833] shadow-xl shadow-[#002833]/20 backdrop-blur transition hover:-translate-y-0.5 hover:bg-white focus:outline-none focus:ring-4 focus:ring-white/40">
                            <svg class="size-5 transition group-hover:scale-110" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" aria-hidden="true">
                                <path stroke-linecap="round" stroke-linejoin="round" d="M21 8.25c0-2.485-2.099-4.5-4.688-4.5-1.935 0-3.597 1.126-4.312 2.733C11.285 4.876 9.623 3.75 7.688 3.75 5.098 3.75 3 5.765 3 8.25c0 7.22 9 12 9 12s9-4.78 9-12Z" />
                            </svg>
                            <span>{{ $beach->favorited_by_users_count }}</span>
                        </a>
                    @endauth
                </div>

                <div class="absolute bottom-0 left-0 right-0 p-6 md:p-8">
                    <div class="flex flex-wrap gap-2">
                        <span class="rounded-full bg-white/90 px-3 py-1 text-xs font-bold text-[#114857] shadow-sm backdrop-blur">{{ $beach->location?->name }}</span>

                        @if ($beach->difficulty)
                            <span class="rounded-full bg-[#002833]/85 px-3 py-1 text-xs font-bold text-white shadow-sm backdrop-blur">{{ $difficulties[$beach->difficulty] }}</span>
                        @endif
                    </div>

                    <h1 class="mt-4 max-w-4xl text-4xl font-black tracking-tight text-white md:text-6xl">{{ $beach->name }}</h1>

                    @if ($beach->short_description)
                        <p class="mt-4 max-w-3xl text-base leading-7 text-white/90 md:text-lg">{{ $beach->short_description }}</p>
                    @endif
                </div>
            </div>
        </section>

        <div class="mt-8 grid gap-8 xl:grid-cols-[1fr_360px]">
            <div class="space-y-8">
                <section class="rounded-[2rem] border border-[#85C3D4]/40 bg-white/75 p-6 shadow-xl shadow-[#114857]/5 backdrop-blur md:p-8">
                    <h2 class="text-2xl font-black text-[#002833]">Descripción</h2>
                    <p class="mt-5 whitespace-pre-line text-base leading-8 text-[#266C80]">{{ $beach->description ?: 'Esta playa aún no tiene una descripción completa.' }}</p>
                </section>

                <section id="comentarios" class="rounded-[2rem] border border-[#85C3D4]/40 bg-white/70 p-6 shadow-xl shadow-[#114857]/5 backdrop-blur md:p-8">
                    <div class="flex flex-col gap-3 md:flex-row md:items-end md:justify-between">
                        <div>
                            <p class="text-sm font-bold uppercase tracking-[0.28em] text-[#5097AB]">Comunidad</p>
                            <h2 class="mt-2 text-2xl font-black text-[#002833]">Comentarios</h2>
                        </div>

                        <span class="text-sm font-bold text-[#5097AB]">
                            {{ $beach->published_comments_count }} {{ $beach->published_comments_count === 1 ? 'comentario' : 'comentarios' }}
                        </span>
                    </div>

                    @auth
                        <form method="POST" action="{{ route('beaches.comments.store', $beach) }}" class="mt-6 rounded-[1.5rem] bg-[#DCEFF4]/45 p-4">
                            @csrf

                            <label for="content" class="sr-only">Publicar comentario</label>
                            <textarea id="content" name="content" rows="4" maxlength="1000" placeholder="Comparte algo útil sobre esta playa..." class="block w-full resize-none rounded-[1.25rem] bg-white px-4 py-3 text-sm leading-6 text-[#002833] shadow-sm outline-none transition placeholder:text-[#5097AB]/70 focus:ring-4 focus:ring-[#85C3D4]/30">{{ old('content') }}</textarea>

                            @error('content')
                                <p class="mt-2 text-sm font-semibold text-red-700">{{ $message }}</p>
                            @enderror

                            <div class="mt-3 flex justify-end">
                                <button type="submit" class="rounded-full bg-[#002833] px-5 py-2.5 text-sm font-bold text-white shadow-lg shadow-[#114857]/15 transition hover:-translate-y-0.5 hover:bg-[#114857]">Publicar</button>
                            </div>
                        </form>
                    @else
                        <div class="mt-6 rounded-[1.5rem] bg-[#DCEFF4]/45 p-4 text-sm font-semibold text-[#266C80]">
                            <a href="{{ route('login') }}" class="font-black text-[#002833] transition hover:text-[#266C80]">Inicia sesión</a> para comentar esta playa.
                        </div>
                    @endauth

                    <div class="mt-7 space-y-5">
                        @forelse ($comments as $comment)
                            <article class="flex gap-4">
                                <div class="flex size-11 shrink-0 items-center justify-center rounded-full bg-[#002833] text-sm font-black text-white shadow-md shadow-[#114857]/15">
                                    {{ $comment->user->initials() }}
                                </div>

                                <div class="min-w-0 flex-1 border-b border-[#85C3D4]/25 pb-5 last:border-b-0 last:pb-0">
                                    <div class="flex flex-wrap items-center gap-x-3 gap-y-1">
                                        <h3 class="font-bold text-[#002833]">{{ $comment->user->name }}</h3>
                                        <time datetime="{{ $comment->created_at->toIso8601String() }}" class="text-xs font-semibold text-[#5097AB]">{{ $comment->created_at->diffForHumans() }}</time>
                                    </div>

                                    <p class="mt-2 whitespace-pre-line text-sm leading-7 text-[#266C80]">{{ $comment->content }}</p>
                                </div>
                            </article>
                        @empty
                            <p class="rounded-[1.5rem] bg-white/70 p-5 text-sm font-semibold leading-6 text-[#266C80] shadow-sm shadow-[#114857]/5">Todavía no hay comentarios. Sé la primera persona en compartir algo útil sobre esta playa.</p>
                        @endforelse
                    </div>

                    @if ($comments->hasPages())
                        <div class="mt-6 rounded-[1.5rem] bg-white/70 px-4 py-3 shadow-sm shadow-[#114857]/5">
                            {{ $comments->links() }}
                        </div>
                    @endif
                </section>
            </div>

            <aside class="space-y-5 xl:sticky xl:top-6 xl:self-start">
                <section class="rounded-[2rem] border border-[#85C3D4]/40 bg-white/75 p-6 shadow-xl shadow-[#114857]/5 backdrop-blur">
                    <h2 class="text-lg font-black text-[#002833]">Servicios</h2>

                    <div class="mt-5 flex flex-wrap gap-2">
                        @forelse ($beach->amenities as $amenity)
                            <span class="rounded-full bg-[#85C3D4]/12 px-4 py-2 text-sm font-bold text-[#114857] shadow-sm">{{ $amenity->name }}</span>
                        @empty
                            <span class="text-sm font-semibold text-[#5097AB]">Aún no hay servicios indicados.</span>
                        @endforelse
                    </div>
                </section>

                <a href="{{ route('map', ['playa' => $beach->slug]) }}" class="block rounded-[2rem] bg-[#002833] p-6 text-white shadow-xl shadow-[#114857]/15 transition hover:-translate-y-0.5 hover:bg-[#114857]" wire:navigate>
                    <span class="text-sm font-bold uppercase tracking-[0.28em] text-[#85C3D4]">Mapa</span>
                    <span class="mt-2 block text-xl font-black">Ver ubicación</span>
                    <span class="mt-3 block text-sm leading-6 text-white/75">Abre el mapa centrado en esta playa para ver su posición en la costa.</span>
                </a>
            </aside>
        </div>
    </article>
</x-layouts::public>
