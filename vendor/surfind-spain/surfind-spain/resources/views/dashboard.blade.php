<x-layouts::app :title="__('Dashboard')">
    <div class="flex h-full w-full max-w-none flex-1 flex-col gap-6 rounded-xl">
        <header class="flex flex-col gap-3 sm:flex-row sm:items-end sm:justify-between">
            <div>
                <h1 class="text-3xl font-semibold tracking-tight text-[#002833] dark:text-white">Hola, {{ auth()->user()->name }}</h1>
            </div>

            <div class="text-sm sm:text-right">
                <p class="font-medium text-zinc-900 dark:text-white">{{ $generatedAt->translatedFormat('l, d F Y') }}</p>
                <p class="mt-1 text-zinc-500 dark:text-zinc-400">Datos generados a las {{ $generatedAt->format('H:i') }}</p>
            </div>
        </header>

        <section class="rounded-2xl border border-zinc-300 bg-white shadow-sm shadow-[#114857]/5 dark:border-zinc-700 dark:bg-zinc-900">
            <dl class="grid divide-y divide-zinc-200 text-sm dark:divide-zinc-700 sm:grid-cols-2 sm:divide-x sm:divide-y-0 xl:grid-cols-5">
                @foreach ($metrics as $metric)
                    <div class="px-5 py-4">
                        <dt class="text-xs font-semibold uppercase tracking-wide text-zinc-500 dark:text-zinc-400">{{ $metric['label'] }}</dt>
                        <dd class="mt-2 text-2xl font-semibold tracking-tight text-[#002833] dark:text-white">{{ number_format($metric['value'], 0, ',', '.') }}</dd>
                        <p class="mt-1 text-xs text-zinc-500 dark:text-zinc-400">{{ $metric['description'] }}</p>
                    </div>
                @endforeach
            </dl>
        </section>

        <section class="grid gap-6 xl:grid-cols-[1fr_280px]">
            <article class="rounded-2xl border border-zinc-300 bg-white p-5 shadow-sm shadow-[#114857]/5 dark:border-zinc-700 dark:bg-zinc-900 sm:p-6">
                <div class="flex flex-col gap-2 sm:flex-row sm:items-start sm:justify-between">
                    <div>
                        <h2 class="text-lg font-semibold text-[#002833] dark:text-white">Evolución</h2>
                    </div>
                </div>

                <div class="mt-6 h-[26rem]">
                    <canvas data-dashboard-chart-canvas aria-label="Usuarios registrados y comentarios publicados por mes" role="img"></canvas>
                </div>

                <script type="application/json" data-dashboard-chart>@json($chart)</script>
            </article>

            <aside class="rounded-2xl border border-zinc-300 bg-white p-5 shadow-sm shadow-[#114857]/5 dark:border-zinc-700 dark:bg-zinc-900 sm:p-6">
                <h2 class="text-base font-semibold text-[#002833] dark:text-white">Acciones rápidas</h2>

                <div class="mt-5 space-y-3">
                    @can('create beaches')
                        <a href="{{ route('admin.beaches.create') }}" wire:navigate class="flex items-center justify-between rounded-xl border border-zinc-200 px-4 py-3 text-sm font-semibold text-zinc-800 transition hover:border-[#5097AB] hover:bg-[#85C3D4]/8 dark:border-zinc-700 dark:text-zinc-200 dark:hover:border-[#85C3D4]/50">
                            Crear playa
                            <span class="text-[#5097AB]">+</span>
                        </a>
                    @endcan

                    @can('view beaches')
                        <a href="{{ route('admin.beaches.index') }}" wire:navigate class="flex items-center justify-between rounded-xl border border-zinc-200 px-4 py-3 text-sm font-semibold text-zinc-800 transition hover:border-[#5097AB] hover:bg-[#85C3D4]/8 dark:border-zinc-700 dark:text-zinc-200 dark:hover:border-[#85C3D4]/50">
                            Gestionar playas
                            <span class="text-[#5097AB]">→</span>
                        </a>
                    @endcan

                    @can('manage users')
                        <a href="{{ route('admin.users.index') }}" wire:navigate class="flex items-center justify-between rounded-xl border border-zinc-200 px-4 py-3 text-sm font-semibold text-zinc-800 transition hover:border-[#5097AB] hover:bg-[#85C3D4]/8 dark:border-zinc-700 dark:text-zinc-200 dark:hover:border-[#85C3D4]/50">
                            Gestionar usuarios
                            <span class="text-[#5097AB]">→</span>
                        </a>
                    @endcan

                    <a href="{{ route('home') }}" wire:navigate class="flex items-center justify-between rounded-xl border border-zinc-200 px-4 py-3 text-sm font-semibold text-zinc-800 transition hover:border-[#5097AB] hover:bg-[#85C3D4]/8 dark:border-zinc-700 dark:text-zinc-200 dark:hover:border-[#85C3D4]/50">
                        Ver sitio publico
                        <span class="text-[#5097AB]">→</span>
                    </a>
                </div>
            </aside>
        </section>
    </div>
</x-layouts::app>
