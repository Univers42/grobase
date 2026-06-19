@php
    $isEdit = $beach?->exists ?? false;
    $selectedAmenities = collect(old('amenities', $beach?->amenities?->pluck('id')->all() ?? []))
        ->map(fn ($id) => (int) $id)
        ->all();
    $currentExternalUrl = $beach?->coverImage?->source_type === 'url' ? $beach->coverImage->external_url : null;
@endphp

<form method="POST" action="{{ $isEdit ? route('admin.beaches.update', $beach) : route('admin.beaches.store') }}" enctype="multipart/form-data" class="rounded-2xl border border-zinc-300 bg-white p-6 shadow-sm shadow-[#114857]/5 dark:border-zinc-700 dark:bg-zinc-900">
    @csrf
    @if ($isEdit)
        @method('PUT')
    @endif

    <div class="space-y-8">
        <section>
            <div class="mb-5">
                <h2 class="text-base font-semibold text-[#002833] dark:text-white">Información principal</h2>
            </div>

            <div>
                <flux:input name="name" label="Nombre" value="{{ old('name', $beach?->name) }}" type="text" required autofocus maxlength="255" placeholder="Playa de Somo" />
            </div>

            <div class="mt-6 grid gap-6 lg:grid-cols-3">
                <flux:select name="location_id" label="Provincia" required>
                    <flux:select.option value="">Selecciona provincia</flux:select.option>
                    @foreach ($locations as $location)
                        <flux:select.option value="{{ $location->id }}" :selected="(int) old('location_id', $beach?->location_id) === $location->id">{{ $location->name }}</flux:select.option>
                    @endforeach
                </flux:select>

                <flux:select name="difficulty" label="Dificultad">
                    <flux:select.option value="">Sin definir</flux:select.option>
                    @foreach ($difficulties as $value => $label)
                        <flux:select.option value="{{ $value }}" :selected="old('difficulty', $beach?->difficulty) === $value">{{ $label }}</flux:select.option>
                    @endforeach
                </flux:select>

                <flux:select name="status" label="Estado" required>
                    @foreach ($statuses as $value => $label)
                        <flux:select.option value="{{ $value }}" :selected="old('status', $beach?->status ?? 'draft') === $value">{{ $label }}</flux:select.option>
                    @endforeach
                </flux:select>
            </div>

            <div class="mt-6">
                <flux:input name="short_description" label="Descripción corta" value="{{ old('short_description', $beach?->short_description) }}" type="text" maxlength="255" placeholder="Resumen breve para listados y tarjetas" />
            </div>

            <div class="mt-6">
                <label for="description" class="mb-2 block text-sm font-medium text-zinc-800 dark:text-zinc-200">Descripción</label>
                <textarea id="description" name="description" rows="7" class="block w-full rounded-lg border border-zinc-300 bg-white px-3 py-2 text-sm text-zinc-900 shadow-xs outline-none transition placeholder:text-zinc-400 focus:border-[#266C80] focus:ring-2 focus:ring-[#85C3D4]/30 dark:border-zinc-700 dark:bg-zinc-950 dark:text-white dark:placeholder:text-zinc-500">{{ old('description', $beach?->description) }}</textarea>
            </div>
        </section>

        <section class="border-t border-zinc-300 pt-8 dark:border-zinc-700">
            <div class="mb-5">
                <h2 class="text-base font-semibold text-[#002833] dark:text-white">Localización</h2>
            </div>

            <div class="grid gap-6 lg:grid-cols-2">
                <flux:input name="latitude" label="Latitud" value="{{ old('latitude', $beach?->latitude) }}" type="number" required step="0.0000001" min="-90" max="90" placeholder="43.4623000" />
                <flux:input name="longitude" label="Longitud" value="{{ old('longitude', $beach?->longitude) }}" type="number" required step="0.0000001" min="-180" max="180" placeholder="-3.7441000" />
            </div>
        </section>

        <section class="border-t border-zinc-300 pt-8 dark:border-zinc-700">
            <div class="mb-5">
                <h2 class="text-base font-semibold text-[#002833] dark:text-white">Imagen de portada</h2>
            </div>

            <div class="grid gap-6 lg:grid-cols-[260px_1fr]">
                <div class="overflow-hidden rounded-2xl border border-zinc-300 bg-[#85C3D4]/10 dark:border-zinc-700">
                    @if ($isEdit && $beach->coverImage?->url())
                        <img src="{{ $beach->coverImage->url() }}" alt="{{ $beach->coverImage->alt_text ?? $beach->name }}" class="h-44 w-full object-cover">
                    @else
                        <div class="grid h-44 place-items-center text-[#114857] dark:text-[#85C3D4]">
                            <div class="text-center">
                                <svg class="mx-auto size-9" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" aria-hidden="true">
                                    <path stroke-linecap="round" stroke-linejoin="round" d="M3 17c3-4 6-4 9 0s6 4 9 0M4 13c2-2 4-2 6 0s4 2 6 0 3-2 4-1M8 7h.01M5 21h14a2 2 0 0 0 2-2V5a2 2 0 0 0-2-2H5a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2Z" />
                                </svg>
                                <p class="mt-2 text-xs font-medium">Sin portada</p>
                            </div>
                        </div>
                    @endif
                </div>

                <div class="grid gap-5 md:grid-cols-2">
                    <flux:select name="cover_source" label="Origen de la portada">
                        <flux:select.option value="" :selected="old('cover_source') === null">{{ $isEdit ? 'No cambiar portada' : 'Sin portada por ahora' }}</flux:select.option>
                        <flux:select.option value="upload" :selected="old('cover_source') === 'upload'">Subir imagen</flux:select.option>
                        <flux:select.option value="url" :selected="old('cover_source') === 'url'">URL externa</flux:select.option>
                    </flux:select>

                    <flux:input name="cover_alt_text" label="Texto alternativo" value="{{ old('cover_alt_text', $beach?->coverImage?->alt_text) }}" type="text" maxlength="255" placeholder="Vista de la playa" />

                    <div>
                        <label for="cover_image" class="mb-2 block text-sm font-medium text-zinc-800 dark:text-zinc-200">Archivo</label>
                        <input id="cover_image" name="cover_image" type="file" accept="image/png,image/jpeg,image/webp" class="block w-full text-sm text-zinc-700 file:me-4 file:rounded-lg file:border-0 file:bg-[#114857] file:px-4 file:py-2 file:text-sm file:font-medium file:text-white hover:file:bg-[#266C80] dark:text-zinc-300">
                        <p class="mt-2 text-xs text-zinc-500 dark:text-zinc-400">JPG, PNG o WEBP. Máximo 4MB.</p>
                    </div>

                    <flux:input name="cover_image_url" label="URL externa" value="{{ old('cover_image_url', $currentExternalUrl) }}" type="url" maxlength="2048" placeholder="https://..." />
                </div>
            </div>
        </section>

        <section class="border-t border-zinc-300 pt-8 dark:border-zinc-700">
            <div class="mb-5">
                <h2 class="text-base font-semibold text-[#002833] dark:text-white">Servicios</h2>
            </div>

            <div class="grid gap-3 sm:grid-cols-2 xl:grid-cols-3">
                @forelse ($amenities as $amenity)
                    <label class="flex items-center gap-3 rounded-xl border border-zinc-300 px-4 py-3 text-sm transition hover:border-[#266C80] hover:bg-[#85C3D4]/5 dark:border-zinc-700 dark:hover:border-[#85C3D4]/50">
                        <input type="checkbox" name="amenities[]" value="{{ $amenity->id }}" @checked(in_array($amenity->id, $selectedAmenities, true)) class="size-4 rounded border-zinc-300 text-[#114857] focus:ring-[#85C3D4]">
                        <span class="font-medium text-zinc-800 dark:text-zinc-200">{{ $amenity->name }}</span>
                    </label>
                @empty
                    <p class="text-sm text-zinc-500 dark:text-zinc-400">No hay servicios creados todavía</p>
                @endforelse
            </div>
        </section>

        <div class="flex flex-col-reverse gap-3 border-t border-zinc-300 pt-6 dark:border-zinc-700 sm:flex-row sm:justify-end">
            <flux:button :href="$isEdit ? route('admin.beaches.show', $beach) : route('admin.beaches.index')" wire:navigate>
                Cancelar
            </flux:button>

            <flux:button type="submit" variant="primary" class="bg-[#114857] hover:bg-[#266C80]">
                {{ $isEdit ? 'Guardar cambios' : 'Crear playa' }}
            </flux:button>
        </div>
    </div>
</form>
