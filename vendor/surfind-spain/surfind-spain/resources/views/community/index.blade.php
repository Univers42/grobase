<x-layouts::public :title="__('Comunidad')">
    @php
        $desktopPodiumOrder = collect([$topBeaches->get(1), $topBeaches->get(0), $topBeaches->get(2)])->filter();
        $remainingBeaches = $topBeaches->slice(3);
        $totalFavorites = $topBeaches->sum('favorited_by_users_count');
    @endphp

    <section class="relative z-10 mx-auto flex max-w-7xl flex-col gap-9 px-5 pb-16 pt-8 sm:px-8 lg:px-10">
        <div class="relative overflow-hidden rounded-[2.25rem] bg-[#002833] px-6 py-10 text-white shadow-2xl shadow-[#114857]/20 sm:px-10 lg:px-12">
            <div class="absolute -right-16 -top-20 size-72 rounded-full bg-[#85C3D4]/18 blur-3xl"></div>
            <div class="absolute -bottom-24 left-8 size-64 rounded-full bg-[#5097AB]/18 blur-3xl"></div>

            <div class="relative grid gap-8 lg:grid-cols-[1fr_280px] lg:items-end">
                <div class="max-w-3xl">
                    <p class="text-xs font-black uppercase tracking-[0.32em] text-[#85C3D4]">Comunidad</p>
                    <h1 class="mt-4 text-4xl font-black tracking-tight sm:text-5xl lg:text-6xl">Las 5 playas que más surfistas han guardado en Surfind Spain</h1>
                </div>
            </div>
        </div>

        @if ($topBeaches->isNotEmpty())
            <div class="lg:hidden">
                <div class="space-y-4">
                    @foreach ($topBeaches as $beach)
                        @php
                            $rank = $loop->iteration;
                            $coverUrl = $beach->coverImage?->url();
                        @endphp

                        <article class="overflow-hidden rounded-[2rem] border border-[#85C3D4]/35 bg-white/80 shadow-xl shadow-[#114857]/6 backdrop-blur">
                            <div class="grid grid-cols-[6rem_1fr]">
                                <a href="{{ route('beaches.show', $beach) }}" wire:navigate class="relative block min-h-32 overflow-hidden bg-[#85C3D4]/15">
                                    @if ($coverUrl)
                                        <img src="{{ $coverUrl }}" alt="{{ $beach->coverImage?->alt_text ?? $beach->name }}" class="h-full w-full object-cover">
                                    @else
                                        <div class="grid h-full place-items-center text-[#114857]">
                                            <svg class="size-9" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" aria-hidden="true">
                                                <path stroke-linecap="round" stroke-linejoin="round" d="M3 17c3-4 6-4 9 0s6 4 9 0M4 13c2-2 4-2 6 0s4 2 6 0 3-2 4-1M8 7h.01M5 21h14a2 2 0 0 0 2-2V5a2 2 0 0 0-2-2H5a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2Z" />
                                            </svg>
                                        </div>
                                    @endif

                                    <span class="absolute left-3 top-3 grid size-10 place-items-center rounded-full bg-[#002833] text-lg font-black text-white shadow-lg shadow-[#002833]/20">{{ $rank }}</span>
                                </a>

                                <div class="flex flex-col justify-between p-4">
                                    <div>
                                        <p class="text-xs font-black uppercase tracking-[0.22em] text-[#5097AB]">{{ $rank === 1 ? 'Favorita' : 'Puesto '.$rank }}</p>
                                        <h2 class="mt-1 text-xl font-black text-[#002833]">{{ $beach->name }}</h2>
                                        <p class="mt-1 text-sm font-semibold text-[#266C80]">{{ $beach->location?->name }}</p>
                                    </div>

                                    <div class="mt-4 flex items-center justify-between gap-3">
                                        <span class="rounded-full bg-[#DCEFF4] px-3 py-1.5 text-sm font-black text-[#002833]">{{ $beach->favorited_by_users_count }} favoritos</span>
                                        <a href="{{ route('beaches.show', $beach) }}" wire:navigate class="text-sm font-black text-[#002833] transition hover:text-[#266C80]">Ver ficha</a>
                                    </div>
                                </div>
                            </div>
                        </article>
                    @endforeach
                </div>
            </div>

            <div class="hidden lg:block">
                <div class="rounded-[2.5rem] border border-[#85C3D4]/35 bg-white/55 p-6 shadow-2xl shadow-[#114857]/8 backdrop-blur xl:p-8">
                    <div class="grid items-end gap-5 lg:grid-cols-3">
                        @foreach ($desktopPodiumOrder as $beach)
                            @php
                                $rank = $topBeaches->search(fn ($topBeach) => $topBeach->is($beach)) + 1;
                                $coverUrl = $beach->coverImage?->url();
                                $isWinner = $rank === 1;
                                $heightClass = $isWinner ? 'min-h-[31rem]' : ($rank === 2 ? 'min-h-[27rem]' : 'min-h-[24rem]');
                                $pedestalClass = $isWinner ? 'bg-[#002833] text-white' : 'bg-white/90 text-[#002833]';
                                $rankClass = $isWinner ? 'bg-white text-[#002833]' : 'bg-[#002833] text-white';
                            @endphp

                            <article class="group flex {{ $heightClass }} flex-col overflow-hidden rounded-[2.25rem] border {{ $isWinner ? 'border-[#002833]/10 shadow-2xl shadow-[#002833]/18' : 'border-[#85C3D4]/35 shadow-xl shadow-[#114857]/6' }} {{ $pedestalClass }} transition duration-300 hover:-translate-y-1">
                                <a href="{{ route('beaches.show', $beach) }}" wire:navigate class="relative block h-64 overflow-hidden bg-[#85C3D4]/15">
                                    @if ($coverUrl)
                                        <img src="{{ $coverUrl }}" alt="{{ $beach->coverImage?->alt_text ?? $beach->name }}" class="h-full w-full object-cover transition duration-500 group-hover:scale-105">
                                    @else
                                        <div class="grid h-full place-items-center {{ $isWinner ? 'bg-[#114857] text-[#85C3D4]' : 'text-[#114857]' }}">
                                            <svg class="size-14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" aria-hidden="true">
                                                <path stroke-linecap="round" stroke-linejoin="round" d="M3 17c3-4 6-4 9 0s6 4 9 0M4 13c2-2 4-2 6 0s4 2 6 0 3-2 4-1M8 7h.01M5 21h14a2 2 0 0 0 2-2V5a2 2 0 0 0-2-2H5a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2Z" />
                                            </svg>
                                        </div>
                                    @endif

                                    <div class="absolute inset-x-0 bottom-0 h-28 bg-gradient-to-t {{ $isWinner ? 'from-[#002833]' : 'from-[#002833]/72' }} to-transparent"></div>
                                    <span class="absolute left-5 top-5 grid size-16 place-items-center rounded-full {{ $rankClass }} text-3xl font-black shadow-xl shadow-[#002833]/20">{{ $rank }}</span>

                                    @if ($isWinner)
                                        <span class="absolute bottom-5 left-5 rounded-full bg-white/92 px-4 py-2 text-xs font-black uppercase tracking-[0.18em] text-[#002833] shadow-lg shadow-[#002833]/20">Favorita de la comunidad</span>
                                    @endif
                                </a>

                                <div class="flex flex-1 flex-col justify-between p-6">
                                    <div>
                                        <p class="text-xs font-black uppercase tracking-[0.24em] {{ $isWinner ? 'text-[#85C3D4]' : 'text-[#5097AB]' }}">Puesto {{ $rank }}</p>
                                        <h2 class="mt-2 text-3xl font-black tracking-tight {{ $isWinner ? 'text-white' : 'text-[#002833]' }}">{{ $beach->name }}</h2>
                                        <p class="mt-2 text-sm font-semibold {{ $isWinner ? 'text-[#DCEFF4]' : 'text-[#266C80]' }}">{{ $beach->location?->name }}</p>
                                    </div>

                                    <div class="mt-7 flex items-center justify-between gap-4 border-t pt-5 {{ $isWinner ? 'border-white/12' : 'border-[#85C3D4]/25' }}">
                                        <div>
                                            <p class="text-4xl font-black leading-none">{{ $beach->favorited_by_users_count }}</p>
                                            <p class="mt-1 text-xs font-black uppercase tracking-[0.18em] {{ $isWinner ? 'text-[#85C3D4]' : 'text-[#5097AB]' }}">favoritos</p>
                                        </div>

                                        <a href="{{ route('beaches.show', $beach) }}" wire:navigate class="rounded-full {{ $isWinner ? 'bg-white text-[#002833] hover:bg-[#DCEFF4]' : 'bg-[#002833] text-white hover:bg-[#114857]' }} px-5 py-3 text-sm font-black shadow-lg shadow-[#114857]/12 transition hover:-translate-y-0.5">Ver ficha</a>
                                    </div>
                                </div>
                            </article>
                        @endforeach
                    </div>
                </div>

                @if ($remainingBeaches->isNotEmpty())
                    <div class="mt-6 rounded-[2rem] border border-[#85C3D4]/35 bg-white/70 p-4 shadow-xl shadow-[#114857]/6 backdrop-blur">
                        <div class="grid gap-3 xl:grid-cols-2">
                            @foreach ($remainingBeaches as $beach)
                                @php
                                    $rank = $loop->iteration + 3;
                                @endphp

                                <article class="flex items-center justify-between gap-5 rounded-[1.5rem] bg-white/80 p-4 shadow-sm shadow-[#114857]/5">
                                    <div class="flex min-w-0 items-center gap-4">
                                        <span class="grid size-12 shrink-0 place-items-center rounded-full bg-[#DCEFF4] text-lg font-black text-[#002833]">{{ $rank }}</span>
                                        <div class="min-w-0">
                                            <h2 class="truncate text-lg font-black text-[#002833]">{{ $beach->name }}</h2>
                                            <p class="mt-1 text-sm font-semibold text-[#266C80]">{{ $beach->location?->name }}</p>
                                        </div>
                                    </div>

                                    <div class="flex shrink-0 items-center gap-4">
                                        <span class="rounded-full bg-[#DCEFF4] px-3 py-1.5 text-sm font-black text-[#002833]">{{ $beach->favorited_by_users_count }} favoritos</span>
                                        <a href="{{ route('beaches.show', $beach) }}" wire:navigate class="text-sm font-black text-[#002833] transition hover:text-[#266C80]">Ver ficha</a>
                                    </div>
                                </article>
                            @endforeach
                        </div>
                    </div>
                @endif
            </div>
        @else
            <div class="rounded-[2rem] border border-[#85C3D4]/45 bg-white/75 px-6 py-14 text-center shadow-xl shadow-[#114857]/5 backdrop-blur">
                <h2 class="text-2xl font-black text-[#002833]">Todavía no hay playas en el ranking</h2>
            </div>
        @endif
    </section>
</x-layouts::public>
