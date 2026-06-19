<x-layouts::app :title="__('Crear playa')">
    <div class="flex h-full w-full max-w-none flex-1 flex-col gap-6 rounded-xl">
        <div class="flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between">
            <div>
                <h1 class="text-2xl font-semibold text-[#002833] dark:text-white">Crear playa</h1>
                <p class="mt-1 text-sm text-zinc-600 dark:text-zinc-400">Alta editorial de una playa con ubicación, estado, servicios y portada.</p>
            </div>

            <flux:button :href="route('admin.beaches.index')" wire:navigate>
                Volver al listado
            </flux:button>
        </div>

        @include('admin.beaches._form')
    </div>
</x-layouts::app>
