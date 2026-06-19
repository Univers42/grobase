<x-layouts::app :title="__('Editar playa')">
    <div class="flex h-full w-full max-w-none flex-1 flex-col gap-6 rounded-xl">
        <div class="flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between">
            <div>
                <h1 class="text-2xl font-semibold text-[#002833] dark:text-white">Editar {{ $beach->name }}</h1>
            </div>

            <div class="flex flex-wrap gap-2">
                <flux:button :href="route('admin.beaches.show', $beach)" wire:navigate>
                    Ver ficha
                </flux:button>

                <flux:button :href="route('admin.beaches.index')" wire:navigate>
                    Volver al listado
                </flux:button>
            </div>
        </div>

        @include('admin.beaches._form')
    </div>
</x-layouts::app>
