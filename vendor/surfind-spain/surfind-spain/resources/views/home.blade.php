<x-layouts::public :title="__('Inicio')">
    @php
        $headlineWords = ['¿Buscas', 'una', 'playa', 'para', 'hacer', 'surf?'];
    @endphp

    <section class="surfind-home-hero relative isolate grid min-h-screen place-items-center overflow-hidden px-5 py-32 text-center sm:px-8 lg:px-10">
        <div class="surfind-home-video-slot" aria-hidden="true">
            <video class="surfind-home-video" autoplay muted loop playsinline poster="/videos/home-surf-poster.webp" aria-hidden="true">
                <source src="/videos/home-surf.mp4" type="video/mp4">
            </video>
        </div>

        <div class="relative z-10 mx-auto max-w-5xl">
            <h1 class="surfind-wave-title text-balance text-5xl font-black leading-[0.98] tracking-[-0.06em] text-white sm:text-7xl lg:text-8xl">
                @foreach ($headlineWords as $index => $word)
                    <span style="--surfind-wave-delay: {{ $index * 90 }}ms">{{ $word }}</span>
                @endforeach
            </h1>

            <a href="{{ route('beaches.index') }}" wire:navigate class="surfind-home-cta group mt-10 inline-flex items-center justify-center rounded-full px-8 py-4 text-lg font-black shadow-2xl transition duration-300 hover:-translate-y-1 sm:px-10 sm:py-5 sm:text-xl">
                <span>Encuéntrala aquí</span>
            </a>
        </div>
    </section>
</x-layouts::public>
