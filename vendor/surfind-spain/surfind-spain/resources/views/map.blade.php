<x-layouts::public :title="__('Mapa')">
    <section class="relative z-10 mx-auto flex max-w-7xl flex-col gap-5 px-5 pb-16 pt-8 sm:px-8 lg:px-10">
        <div>
            <p class="text-sm font-bold uppercase tracking-[0.28em] text-[#5097AB]">Mapa interactivo</p>
            <h1 class="mt-2 text-4xl font-black tracking-tight text-[#002833] md:text-5xl">Explora playas de surf</h1>
        </div>

        @if ($mapBeaches->isNotEmpty())
            <div class="overflow-hidden rounded-[2.25rem] border border-[#85C3D4]/45 bg-white/70 p-2 shadow-2xl shadow-[#114857]/10 backdrop-blur">
                <div
                    id="surfind-map"
                    class="surfind-map h-[38rem] rounded-[1.85rem] bg-[#DCEFF4] md:h-[46rem] xl:h-[52rem]"
                    data-selected-slug="{{ $selectedBeachSlug }}"
                ></div>
            </div>

            <script type="application/json" data-surfind-map-data>{!! $mapBeaches->toJson(JSON_HEX_TAG | JSON_HEX_APOS | JSON_HEX_AMP | JSON_HEX_QUOT) !!}</script>
        @else
            <div class="rounded-[2.25rem] border border-[#85C3D4]/45 bg-white/75 px-6 py-16 text-center shadow-xl shadow-[#114857]/5 backdrop-blur">
                <h2 class="text-2xl font-black text-[#002833]">Aún no hay playas publicadas en el mapa</h2>
            </div>
        @endif
    </section>
</x-layouts::public>
