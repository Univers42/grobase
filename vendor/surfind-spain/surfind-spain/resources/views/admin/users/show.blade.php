<x-layouts::app :title="$user->name">
    <div class="flex h-full w-full max-w-none flex-1 flex-col gap-6 rounded-xl">
        <div class="flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between">
            <div>
                <div class="mb-3 flex items-center gap-3">
                    <div class="grid size-12 place-items-center rounded-2xl bg-[#114857] text-sm font-semibold text-white shadow-sm shadow-[#114857]/20 ring-4 ring-[#85C3D4]/20">
                        {{ $user->initials() }}
                    </div>
                    <div>
                        <h1 class="text-2xl font-semibold text-[#002833] dark:text-white">{{ $user->name }}</h1>
                    </div>
                </div>
            </div>

            <div class="flex flex-wrap gap-2">
                <flux:button :href="route('admin.users.index')" wire:navigate>
                    Volver
                </flux:button>

                @can('manage users')
                    <flux:button :href="route('admin.users.edit', $user)" variant="primary" class="bg-[#114857] hover:bg-[#266C80]" wire:navigate>
                        Editar usuario
                    </flux:button>
                @endcan
            </div>
        </div>

        <div class="grid gap-6 xl:grid-cols-[380px_1fr]">
            <aside class="space-y-6">
                <section class="rounded-2xl border border-zinc-300 bg-white p-6 shadow-sm shadow-[#114857]/5 dark:border-zinc-700 dark:bg-zinc-900">
                    <div class="flex items-center justify-between gap-3">
                        <h2 class="text-base font-semibold text-[#002833] dark:text-white">Resumen</h2>

                        @if ($user->trashed())
                            <span class="rounded-full bg-red-50 px-2.5 py-1 text-xs font-semibold text-red-700 dark:bg-red-500/10 dark:text-red-200">Deshabilitado</span>
                        @else
                            <span class="rounded-full bg-emerald-50 px-2.5 py-1 text-xs font-semibold text-emerald-700 dark:bg-emerald-500/10 dark:text-emerald-200">Activo</span>
                        @endif
                    </div>

                    <dl class="mt-6 space-y-4 text-sm">
                        <div>
                            <dt class="text-xs font-medium uppercase tracking-wide text-zinc-500 dark:text-zinc-400">Correo</dt>
                            <dd class="mt-1 break-all font-medium text-zinc-900 dark:text-white">{{ $user->email }}</dd>
                        </div>

                        <div>
                            <dt class="text-xs font-medium uppercase tracking-wide text-zinc-500 dark:text-zinc-400">Rol</dt>
                            <dd class="mt-1">
                                <span class="rounded-full bg-[#85C3D4]/15 px-2.5 py-1 text-xs font-semibold text-[#114857] dark:bg-[#85C3D4]/10 dark:text-[#85C3D4]">
                                    {{ $user->roles->first()?->name ?? 'Sin rol' }}
                                </span>
                            </dd>
                        </div>

                        <div class="grid grid-cols-2 gap-4">
                            <div>
                                <dt class="text-xs font-medium uppercase tracking-wide text-zinc-500 dark:text-zinc-400">Alta</dt>
                                <dd class="mt-1 font-medium text-zinc-900 dark:text-white">{{ $user->created_at?->format('d/m/Y') }}</dd>
                            </div>

                            <div>
                                <dt class="text-xs font-medium uppercase tracking-wide text-zinc-500 dark:text-zinc-400">Verificado</dt>
                                <dd class="mt-1 font-medium text-zinc-900 dark:text-white">{{ $user->email_verified_at?->format('d/m/Y') ?? 'No' }}</dd>
                            </div>
                        </div>

                        @if ($user->trashed())
                            <div>
                                <dt class="text-xs font-medium uppercase tracking-wide text-zinc-500 dark:text-zinc-400">Deshabilitado</dt>
                                <dd class="mt-1 font-medium text-zinc-900 dark:text-white">{{ $user->deleted_at?->format('d/m/Y H:i') }}</dd>
                            </div>
                        @endif
                    </dl>
                </section>

                <section class="grid grid-cols-3 gap-3">
                    <div class="rounded-2xl border border-zinc-300 bg-white p-4 text-center shadow-sm shadow-[#114857]/5 dark:border-zinc-700 dark:bg-zinc-900">
                        <div class="text-2xl font-semibold text-[#114857] dark:text-[#85C3D4]">{{ $user->comments_count }}</div>
                        <div class="mt-1 text-xs font-medium text-zinc-500 dark:text-zinc-400">Comentarios</div>
                    </div>

                    <div class="rounded-2xl border border-zinc-300 bg-white p-4 text-center shadow-sm shadow-[#114857]/5 dark:border-zinc-700 dark:bg-zinc-900">
                        <div class="text-2xl font-semibold text-[#114857] dark:text-[#85C3D4]">{{ $user->favorite_beaches_count }}</div>
                        <div class="mt-1 text-xs font-medium text-zinc-500 dark:text-zinc-400">Favoritas</div>
                    </div>

                    <div class="rounded-2xl border border-zinc-300 bg-white p-4 text-center shadow-sm shadow-[#114857]/5 dark:border-zinc-700 dark:bg-zinc-900">
                        <div class="text-2xl font-semibold text-[#114857] dark:text-[#85C3D4]">{{ $user->created_beaches_count }}</div>
                        <div class="mt-1 text-xs font-medium text-zinc-500 dark:text-zinc-400">Playas</div>
                    </div>
                </section>
            </aside>

            <section class="rounded-2xl border border-zinc-300 bg-white shadow-sm shadow-[#114857]/5 dark:border-zinc-700 dark:bg-zinc-900">
                <div class="border-b border-zinc-300 bg-[#85C3D4]/5 px-6 py-5 dark:border-zinc-700 dark:bg-[#85C3D4]/5">
                    <div class="flex flex-col gap-1 sm:flex-row sm:items-end sm:justify-between">
                        <div>
                            <h2 class="text-base font-semibold text-[#002833] dark:text-white">Comentarios recientes</h2>
                        </div>
                    </div>
                </div>

                <div class="divide-y divide-zinc-200 dark:divide-white/10">
                    @forelse ($comments as $comment)
                        <article class="px-6 py-5 transition hover:bg-[#85C3D4]/5">
                            <div class="flex flex-col gap-3 lg:flex-row lg:items-start lg:justify-between">
                                <div class="min-w-0 flex-1">
                                    <div class="flex flex-wrap items-center gap-2 text-sm">
                                        <span class="font-medium text-zinc-900 dark:text-white">En {{ $comment->beach?->name ?? 'playa no disponible' }}</span>

                                        @if ($comment->published)
                                            <span class="rounded-full bg-emerald-50 px-2 py-0.5 text-xs font-semibold text-emerald-700 dark:bg-emerald-500/10 dark:text-emerald-200">Publicado</span>
                                        @else
                                            <span class="rounded-full bg-amber-50 px-2 py-0.5 text-xs font-semibold text-amber-700 dark:bg-amber-500/10 dark:text-amber-200">Oculto</span>
                                        @endif
                                    </div>

                                    <p class="mt-2 line-clamp-3 text-sm leading-6 text-zinc-600 dark:text-zinc-300">
                                        {{ $comment->content ?: 'Comentario sin contenido.' }}
                                    </p>
                                </div>

                                <div class="flex shrink-0 items-center gap-2 text-sm text-zinc-500 dark:text-zinc-400">
                                    <span>{{ $comment->created_at?->format('d/m/Y H:i') }}</span>

                                    @can('delete any review')
                                        @if ($comment->published)
                                            <form method="POST" action="{{ route('admin.comments.destroy', $comment) }}" onsubmit="return confirm('El comentario dejará de mostrarse públicamente. ¿Quieres continuar?')">
                                                @csrf
                                                @method('DELETE')

                                                <button type="submit" title="Ocultar comentario" aria-label="Ocultar comentario" class="inline-flex size-8 items-center justify-center rounded-lg text-red-600 transition hover:bg-red-50 hover:text-red-700 focus:outline-none focus:ring-2 focus:ring-red-200 dark:text-red-400 dark:hover:bg-red-500/10 dark:hover:text-red-300">
                                                    <svg class="size-4" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" aria-hidden="true">
                                                        <path stroke-linecap="round" stroke-linejoin="round" d="M6 7h12M9 7V5.5A1.5 1.5 0 0 1 10.5 4h3A1.5 1.5 0 0 1 15 5.5V7m2 0-.7 12.25A2 2 0 0 1 14.3 21H9.7a2 2 0 0 1-2-1.75L7 7m3 4v6m4-6v6" />
                                                    </svg>
                                                </button>
                                            </form>
                                        @endif
                                    @endcan
                                </div>
                            </div>
                        </article>
                    @empty
                        <div class="px-6 py-12 text-center">
                            <p class="text-sm font-medium text-zinc-700 dark:text-zinc-300">Este usuario aún no ha publicado comentarios</p>
                        </div>
                    @endforelse
                </div>

                @if ($comments->hasPages())
                    <div class="border-t border-zinc-200 px-6 py-4 dark:border-white/10">
                        {{ $comments->links() }}
                    </div>
                @endif
            </section>
        </div>
    </div>
</x-layouts::app>
