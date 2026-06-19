@php
    $navigation = [
        ['label' => 'Playas', 'route' => 'beaches.index', 'active' => 'beaches.*'],
        ['label' => 'Mapa', 'route' => 'map', 'active' => 'map'],
        ['label' => 'Comunidad', 'route' => 'community.index', 'active' => 'community.*'],
    ];

    $isHome = request()->routeIs('home');
@endphp

<!DOCTYPE html>
<html lang="{{ str_replace('_', '-', app()->getLocale()) }}">
    <head>
        @include('partials.head')
    </head>
    <body class="min-h-screen bg-[#F7FBFC] text-[#002833] antialiased">
        <div class="min-h-screen overflow-hidden bg-[linear-gradient(180deg,_#F7FBFC_0%,_#DCEFF4_48%,_#F7FBFC_100%)]">
            <header class="{{ $isHome ? 'fixed inset-x-0 top-0 z-50' : 'relative z-20' }}">
                <div class="relative z-30 mx-auto grid max-w-7xl grid-cols-[auto_1fr_auto] items-center gap-4 px-5 py-6 sm:px-8 lg:px-10">
                    <a href="{{ route('home') }}" class="group inline-flex items-center rounded-full border border-[#85C3D4]/55 bg-white/55 p-1 text-[#002833] shadow-sm shadow-[#5097AB]/20 backdrop-blur transition-all duration-500 hover:bg-white/80 hover:pr-6 hover:shadow-lg hover:shadow-[#114857]/10" wire:navigate aria-label="Surfind Spain">
                        <span class="grid size-14 place-items-center rounded-full bg-white text-[#002833] shadow-sm shadow-[#5097AB]/20 transition duration-500 group-hover:scale-95 group-hover:bg-[#002833] group-hover:text-white md:size-16">
                            <x-app-logo-icon class="size-9 fill-current md:size-10" />
                        </span>
                        <span class="hidden max-w-0 translate-x-[-0.75rem] overflow-hidden whitespace-nowrap text-lg font-black tracking-tight text-[#002833] opacity-0 transition-all duration-500 ease-out group-hover:ml-3 group-hover:max-w-52 group-hover:translate-x-0 group-hover:opacity-100 md:inline-block">
                            Surfind Spain
                        </span>
                    </a>

                    <nav class="absolute left-1/2 hidden -translate-x-1/2 items-center gap-1 rounded-full border border-[#85C3D4]/40 bg-white/55 p-1 text-sm font-semibold text-[#266C80] shadow-sm shadow-[#5097AB]/10 backdrop-blur lg:flex">
                        <a href="{{ route('home') }}" class="rounded-full px-4 py-2 transition hover:bg-white hover:text-[#002833] {{ request()->routeIs('home') ? 'bg-white text-[#002833] shadow-sm' : '' }}" wire:navigate>
                            Inicio
                        </a>

                        @foreach ($navigation as $item)
                            <a href="{{ route($item['route']) }}" class="rounded-full px-4 py-2 transition hover:bg-white hover:text-[#002833] {{ request()->routeIs($item['active']) ? 'bg-white text-[#002833] shadow-sm' : '' }}" wire:navigate>
                                {{ $item['label'] }}
                            </a>
                        @endforeach
                    </nav>

                    <div class="justify-self-end text-sm font-semibold">
                        @auth
                            <details class="group relative hidden lg:block" data-user-menu>
                                <summary class="flex cursor-pointer list-none items-center gap-2 rounded-full text-[#114857] transition duration-300 hover:-translate-y-0.5 [&::-webkit-details-marker]:hidden">
                                    <flux:avatar
                                        :name="auth()->user()->name"
                                        :initials="auth()->user()->initials()"
                                        class="size-10"
                                    />
                                    <svg class="size-4 transition duration-300 group-open:rotate-180" viewBox="0 0 20 20" fill="currentColor" aria-hidden="true">
                                        <path fill-rule="evenodd" d="M5.22 7.22a.75.75 0 0 1 1.06 0L10 10.94l3.72-3.72a.75.75 0 1 1 1.06 1.06l-4.25 4.25a.75.75 0 0 1-1.06 0L5.22 8.28a.75.75 0 0 1 0-1.06Z" clip-rule="evenodd" />
                                    </svg>
                                </summary>

                                <div class="absolute right-0 top-full mt-3 w-56 origin-top-right overflow-hidden rounded-3xl border border-[#85C3D4]/40 bg-white/90 p-2 text-sm text-[#114857] opacity-0 shadow-2xl shadow-[#114857]/15 backdrop-blur transition duration-300 group-open:translate-y-0 group-open:opacity-100">
                                    @if (auth()->user()->hasRole(\App\Enums\Roles::ADMIN->value))
                                        <a href="{{ route('dashboard') }}" class="block rounded-2xl px-4 py-3 font-semibold transition hover:bg-[#DCEFF4] hover:text-[#002833]" wire:navigate>
                                            Panel de administración
                                        </a>
                                    @endif

                                    <form method="POST" action="{{ route('logout') }}">
                                        @csrf
                                        <button type="submit" class="w-full rounded-2xl px-4 py-3 text-left font-semibold transition hover:bg-[#DCEFF4] hover:text-[#002833]">
                                            Cerrar sesión
                                        </button>
                                    </form>
                                </div>
                            </details>

                            <details class="group relative z-50 lg:hidden" data-user-menu>
                                <summary class="flex cursor-pointer list-none items-center rounded-full text-[#114857] transition duration-300 hover:-translate-y-0.5 [&::-webkit-details-marker]:hidden">
                                    <flux:avatar
                                        :name="auth()->user()->name"
                                        :initials="auth()->user()->initials()"
                                        class="size-10"
                                    />
                                </summary>

                                <div class="absolute right-0 top-full z-50 mt-3 w-56 origin-top-right overflow-hidden rounded-3xl border border-[#85C3D4]/40 bg-white/95 p-2 text-sm text-[#114857] opacity-0 shadow-2xl shadow-[#114857]/15 backdrop-blur transition duration-300 group-open:translate-y-0 group-open:opacity-100">
                                    @if (auth()->user()->hasRole(\App\Enums\Roles::ADMIN->value))
                                        <a href="{{ route('dashboard') }}" class="block rounded-2xl px-4 py-3 font-semibold transition hover:bg-[#DCEFF4] hover:text-[#002833]" wire:navigate>
                                            Panel de administración
                                        </a>
                                    @endif

                                    <form method="POST" action="{{ route('logout') }}">
                                        @csrf
                                        <button type="submit" class="w-full rounded-2xl px-4 py-3 text-left font-semibold transition hover:bg-[#DCEFF4] hover:text-[#002833]">
                                            Cerrar sesión
                                        </button>
                                    </form>
                                </div>
                            </details>
                        @else
                            <div class="hidden items-center gap-2 lg:flex">
                                <a href="{{ route('login') }}" class="rounded-full border border-[#85C3D4]/45 bg-white/65 px-4 py-2.5 text-[#114857] shadow-sm shadow-[#5097AB]/10 backdrop-blur transition hover:bg-white/85 hover:text-[#002833]" wire:navigate>
                                Entrar
                                </a>
                                @if (Route::has('register'))
                                    <a href="{{ route('register') }}" class="rounded-full bg-[#002833] px-5 py-2.5 text-white shadow-lg shadow-[#114857]/15 transition hover:-translate-y-0.5 hover:bg-[#114857]" wire:navigate>
                                        Crear cuenta
                                    </a>
                                @endif
                            </div>

                            <details class="group relative z-50 lg:hidden" data-user-menu>
                                <summary class="grid size-11 cursor-pointer list-none place-items-center rounded-full border border-[#85C3D4]/45 bg-white/65 text-[#114857] shadow-sm shadow-[#5097AB]/10 transition duration-300 hover:-translate-y-0.5 hover:bg-white hover:text-[#002833] hover:shadow-lg hover:shadow-[#114857]/10 [&::-webkit-details-marker]:hidden" aria-label="Opciones de usuario">
                                    <svg class="size-5 stroke-current" viewBox="0 0 24 24" fill="none" aria-hidden="true">
                                        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15.75 7.5a3.75 3.75 0 1 1-7.5 0 3.75 3.75 0 0 1 7.5 0ZM4.5 20.25a7.5 7.5 0 0 1 15 0" />
                                    </svg>
                                </summary>

                                <div class="absolute right-0 top-full z-50 mt-3 w-48 origin-top-right overflow-hidden rounded-3xl border border-[#85C3D4]/40 bg-white/95 p-2 text-sm text-[#114857] opacity-0 shadow-2xl shadow-[#114857]/15 backdrop-blur transition duration-300 group-open:translate-y-0 group-open:opacity-100">
                                    <a href="{{ route('login') }}" class="block rounded-2xl px-4 py-3 font-semibold transition hover:bg-[#DCEFF4] hover:text-[#002833]" wire:navigate>
                                        Entrar
                                    </a>
                                    @if (Route::has('register'))
                                        <a href="{{ route('register') }}" class="block rounded-2xl bg-[#002833] px-4 py-3 font-semibold text-white transition hover:bg-[#114857]" wire:navigate>
                                            Crear cuenta
                                        </a>
                                    @endif
                                </div>
                            </details>
                        @endauth
                    </div>
                </div>

                <nav class="relative z-10 mx-auto mb-4 flex max-w-[calc(100%-2.5rem)] justify-center gap-2 overflow-x-auto rounded-full border border-[#85C3D4]/40 bg-white/60 p-1 text-sm font-semibold text-[#266C80] shadow-sm backdrop-blur lg:hidden">
                    <a href="{{ route('home') }}" class="shrink-0 rounded-full px-4 py-2 {{ request()->routeIs('home') ? 'bg-white text-[#002833]' : '' }}" wire:navigate>
                        Inicio
                    </a>
                    @foreach ($navigation as $item)
                        <a href="{{ route($item['route']) }}" class="shrink-0 rounded-full px-4 py-2 {{ request()->routeIs($item['active']) ? 'bg-white text-[#002833]' : '' }}" wire:navigate>
                            {{ $item['label'] }}
                        </a>
                    @endforeach
                </nav>
            </header>

            <main>
                {{ $slot }}
            </main>

            <footer class="relative z-10 border-t border-[#85C3D4]/30 bg-white/55 backdrop-blur">
                <div class="mx-auto grid max-w-7xl gap-6 px-5 py-8 text-sm text-[#266C80] sm:px-8 md:grid-cols-3 md:items-center lg:px-10">
                    <div class="flex items-center gap-2">
                        <a href="https://www.linkedin.com/in/davidsotogarcia/" target="blank" class="group grid size-10 place-items-center rounded-full border border-[#85C3D4]/50 bg-white/60 text-[#114857] shadow-sm shadow-[#5097AB]/10 transition duration-300 hover:-translate-y-1 hover:border-[#002833] hover:bg-[#002833] hover:text-white hover:shadow-lg hover:shadow-[#114857]/20" aria-label="LinkedIn">
                            <svg class="size-4 fill-current transition duration-300 group-hover:scale-110" viewBox="0 0 24 24" aria-hidden="true">
                                <path d="M20.45 20.45h-3.56v-5.57c0-1.33-.02-3.04-1.85-3.04-1.85 0-2.14 1.45-2.14 2.95v5.66H9.34V9h3.42v1.56h.05c.48-.9 1.64-1.85 3.37-1.85 3.61 0 4.27 2.38 4.27 5.47v6.27ZM5.32 7.43a2.06 2.06 0 1 1 0-4.12 2.06 2.06 0 0 1 0 4.12Zm1.78 13.02H3.54V9H7.1v11.45ZM22.22 0H1.77C.79 0 0 .77 0 1.72v20.56C0 23.23.79 24 1.77 24h20.45c.98 0 1.78-.77 1.78-1.72V1.72C24 .77 23.2 0 22.22 0Z" />
                            </svg>
                        </a>
                        <a href="https://github.com/dsotogc" target="blank" class="group grid size-10 place-items-center rounded-full border border-[#85C3D4]/50 bg-white/60 text-[#114857] shadow-sm shadow-[#5097AB]/10 transition duration-300 hover:-translate-y-1 hover:border-[#002833] hover:bg-[#002833] hover:text-white hover:shadow-lg hover:shadow-[#114857]/20" aria-label="GitHub">
                            <svg class="size-5 fill-current transition duration-300 group-hover:rotate-6 group-hover:scale-110" viewBox="0 0 24 24" aria-hidden="true">
                                <path d="M12 .5A11.5 11.5 0 0 0 8.36 22.9c.58.11.79-.25.79-.56v-2.14c-3.22.7-3.9-1.38-3.9-1.38-.53-1.34-1.29-1.7-1.29-1.7-1.05-.72.08-.7.08-.7 1.16.08 1.77 1.2 1.77 1.2 1.04 1.76 2.72 1.25 3.38.96.11-.75.41-1.25.74-1.54-2.57-.29-5.27-1.29-5.27-5.73 0-1.27.45-2.3 1.2-3.11-.12-.29-.52-1.47.11-3.07 0 0 .97-.31 3.18 1.19a10.98 10.98 0 0 1 5.8 0c2.2-1.5 3.17-1.19 3.17-1.19.63 1.6.23 2.78.11 3.07.75.81 1.2 1.84 1.2 3.11 0 4.45-2.71 5.43-5.29 5.72.42.36.79 1.07.79 2.16v3.2c0 .31.21.67.8.56A11.5 11.5 0 0 0 12 .5Z" />
                            </svg>
                        </a>
                    </div>

                    <div class="justify-self-start text-left md:justify-self-center md:text-center">
                        <a href="{{ route('home') }}" class="group text-2xl font-black uppercase tracking-[0.28em] text-[#002833] transition duration-300 hover:tracking-[0.34em] hover:text-[#266C80]" wire:navigate>
                            Surfind Spain
                        </a>
                        <p class="mt-2 text-xs italic text-[#266C80]/70">Desarrollado por David Soto García</p>
                    </div>

                    <p class="text-[#266C80]/80 md:justify-self-end md:text-right">Proyecto CFGS Desarrollo de Aplicaciones Web</p>
                </div>
            </footer>
        </div>

        <script>
            document.addEventListener('click', (event) => {
                document.querySelectorAll('[data-user-menu][open]').forEach((menu) => {
                    if (!menu.contains(event.target)) {
                        menu.removeAttribute('open');
                    }
                });
            });

            document.addEventListener('keydown', (event) => {
                if (event.key !== 'Escape') {
                    return;
                }

                document.querySelectorAll('[data-user-menu][open]').forEach((menu) => {
                    menu.removeAttribute('open');
                });
            });
        </script>

        @fluxScripts
    </body>
</html>
