<?php if (!$__raw['isLoggedIn']): ?>
<!-- ═══ HERO SECTION FOR GUESTS ═══ -->
<div class="bg-white border-b border-ig-border">
    <div class="max-w-[935px] mx-auto px-4 py-10 md:py-16">
        <div class="flex flex-col md:flex-row items-center gap-8 md:gap-16">
            <!-- Phone mockup -->
            <div class="flex-shrink-0 relative w-[220px] h-[380px] md:w-[260px] md:h-[440px]">
                <div class="absolute inset-0 bg-gradient-to-br from-purple-500 via-pink-500 to-orange-400 rounded-[2.5rem] shadow-2xl"></div>
                <div class="absolute inset-[3px] bg-gray-900 rounded-[2.4rem] overflow-hidden">
                    <div class="absolute top-3 left-1/2 -translate-x-1/2 w-20 h-5 bg-black rounded-full"></div>
                    <div class="absolute inset-2 top-10 bg-white rounded-2xl overflow-hidden">
                        <!-- Mini app preview -->
                        <div class="h-8 bg-white border-b border-gray-100 flex items-center px-3">
                            <svg class="w-4 h-4 text-gray-800" viewBox="0 0 24 24" fill="none">
                                <rect x="2" y="2" width="20" height="20" rx="6" stroke="currentColor" stroke-width="2"/>
                                <circle cx="12" cy="12" r="5" stroke="currentColor" stroke-width="2"/>
                                <circle cx="18" cy="6" r="1.5" fill="currentColor"/>
                            </svg>
                            <span class="text-[8px] font-bold ml-1.5 text-gray-800">Camagru</span>
                        </div>
                        <div class="space-y-1">
                            <div class="bg-gradient-to-br from-indigo-100 to-purple-100 aspect-square"></div>
                            <div class="px-2 py-1">
                                <div class="flex gap-2 mb-1">
                                    <div class="w-3 h-3 rounded-full bg-pink-200"></div>
                                    <div class="w-3 h-3 rounded-full bg-blue-200"></div>
                                </div>
                                <div class="h-1 bg-gray-100 rounded w-3/4 mb-0.5"></div>
                                <div class="h-1 bg-gray-100 rounded w-1/2"></div>
                            </div>
                            <div class="bg-gradient-to-br from-amber-100 to-pink-100 aspect-square"></div>
                        </div>
                    </div>
                </div>
            </div>

            <!-- Hero text -->
            <div class="text-center md:text-left flex-1">
                <h1 class="text-3xl md:text-5xl font-extrabold text-ig-text tracking-tight leading-tight mb-4">
                    Capture, Create,<br>
                    <span class="bg-gradient-to-r from-purple-600 via-pink-500 to-orange-400 bg-clip-text text-transparent">Share Moments</span>
                </h1>
                <p class="text-ig-muted text-base md:text-lg mb-8 max-w-md">
                    Take photos with your webcam, add creative overlays, and share your art with the community.
                </p>
                <div class="flex flex-col sm:flex-row gap-3 justify-center md:justify-start">
                    <a href="/register" class="inline-flex items-center justify-center gap-2 bg-ig-blue hover:bg-blue-600 text-white px-8 py-3 rounded-lg font-semibold text-sm transition-colors shadow-lg shadow-blue-500/25">
                        Sign Up — It's Free
                    </a>
                    <a href="/login" class="inline-flex items-center justify-center gap-2 text-ig-blue hover:text-blue-700 px-8 py-3 rounded-lg font-semibold text-sm border border-ig-border hover:border-blue-200 transition-colors">
                        Log In
                    </a>
                </div>
                <div class="flex items-center gap-6 mt-8 justify-center md:justify-start text-sm text-ig-muted">
                    <div class="flex items-center gap-1.5">
                        <svg class="w-5 h-5 text-pink-500" fill="currentColor" viewBox="0 0 24 24"><path d="M3 9a2 2 0 012-2h.93a2 2 0 001.664-.89l.812-1.22A2 2 0 0110.07 4h3.86a2 2 0 011.664.89l.812 1.22A2 2 0 0018.07 7H19a2 2 0 012 2v9a2 2 0 01-2 2H5a2 2 0 01-2-2V9z"/><circle cx="12" cy="13" r="3" fill="white"/></svg>
                        Webcam
                    </div>
                    <div class="flex items-center gap-1.5">
                        <svg class="w-5 h-5 text-purple-500" fill="currentColor" viewBox="0 0 24 24"><path d="M4 16l4.586-4.586a2 2 0 012.828 0L16 16m-2-2l1.586-1.586a2 2 0 012.828 0L20 14m-6-6h.01M6 20h12a2 2 0 002-2V6a2 2 0 00-2-2H6a2 2 0 00-2 2v12a2 2 0 002 2z"/></svg>
                        Overlays
                    </div>
                    <div class="flex items-center gap-1.5">
                        <svg class="w-5 h-5 text-orange-500" fill="currentColor" viewBox="0 0 24 24"><path d="M4.318 6.318a4.5 4.5 0 000 6.364L12 20.364l7.682-7.682a4.5 4.5 0 00-6.364-6.364L12 7.636l-1.318-1.318a4.5 4.5 0 00-6.364 0z"/></svg>
                        Social
                    </div>
                </div>
            </div>
        </div>
    </div>
</div>
<?php endif; ?>

<!-- ═══ GALLERY FEED ═══ -->
<div class="max-w-[470px] mx-auto px-4 py-6 md:py-8">

    <?php if (empty($__raw['posts'])): ?>
        <!-- ── Empty State ── -->
        <div class="bg-white border border-ig-border rounded-lg text-center py-16 px-8">
            <div class="w-20 h-20 mx-auto mb-6 border-2 border-ig-text rounded-full flex items-center justify-center">
                <svg class="w-10 h-10 text-ig-text" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="1.5">
                    <path stroke-linecap="round" stroke-linejoin="round" d="M3 9a2 2 0 012-2h.93a2 2 0 001.664-.89l.812-1.22A2 2 0 0110.07 4h3.86a2 2 0 011.664.89l.812 1.22A2 2 0 0018.07 7H19a2 2 0 012 2v9a2 2 0 01-2 2H5a2 2 0 01-2-2V9z"/>
                    <circle cx="12" cy="13" r="3"/>
                </svg>
            </div>
            <h2 class="text-2xl font-light text-ig-text mb-2">Share Photos</h2>
            <p class="text-ig-muted text-sm mb-6">When people share photos, they'll appear here.</p>
            <?php if ($__raw['isLoggedIn']): ?>
                <a href="/editor" class="inline-flex items-center gap-2 bg-ig-blue hover:bg-blue-600 text-white px-6 py-2.5 rounded-lg transition-colors font-semibold text-sm">
                    Share your first photo
                </a>
            <?php else: ?>
                <a href="/register" class="inline-flex items-center gap-2 bg-ig-blue hover:bg-blue-600 text-white px-6 py-2.5 rounded-lg transition-colors font-semibold text-sm">
                    Create an account
                </a>
            <?php endif; ?>
        </div>
    <?php else: ?>

        <!-- ── Posts Feed ── -->
        <div id="gallery-feed" class="space-y-4">
            <?php foreach ($__raw['posts'] as $idx => $post): ?>
                <article class="bg-white border border-ig-border rounded-lg overflow-hidden fade-in-up"
                         data-post-id="<?= (int)$post['id'] ?>"
                         style="animation-delay: <?= $idx * 0.08 ?>s">

                    <!-- Author bar -->
                    <div class="flex items-center gap-3 px-4 py-3">
                        <div class="w-8 h-8 rounded-full bg-gradient-to-br from-yellow-400 via-pink-500 to-purple-600 p-[2px] flex-shrink-0">
                            <div class="w-full h-full rounded-full bg-white flex items-center justify-center">
                                <span class="text-xs font-semibold text-ig-text"><?= strtoupper(substr(htmlspecialchars($post['author']), 0, 1)) ?></span>
                            </div>
                        </div>
                        <div class="flex-1 min-w-0">
                            <span class="text-sm font-semibold text-ig-text"><?= htmlspecialchars($post['author']) ?></span>
                        </div>
                        <button class="text-ig-text hover:opacity-60">
                            <svg class="w-5 h-5" fill="currentColor" viewBox="0 0 24 24"><circle cx="12" cy="6" r="1.5"/><circle cx="12" cy="12" r="1.5"/><circle cx="12" cy="18" r="1.5"/></svg>
                        </button>
                    </div>

                    <!-- Image -->
                    <div class="bg-gray-50 aspect-square relative overflow-hidden">
                        <img src="<?= htmlspecialchars($post['image_path']) ?>"
                             alt="Creation by <?= htmlspecialchars($post['author']) ?>"
                             class="w-full h-full object-cover"
                             loading="lazy"
                             onerror="this.parentElement.classList.add('flex','items-center','justify-center'); this.outerHTML='<div class=\'text-center p-8\'><svg class=\'w-16 h-16 text-gray-300 mx-auto mb-2\' fill=\'none\' viewBox=\'0 0 24 24\' stroke=\'currentColor\'><path stroke-linecap=\'round\' stroke-linejoin=\'round\' stroke-width=\'1\' d=\'M4 16l4.586-4.586a2 2 0 012.828 0L16 16m-2-2l1.586-1.586a2 2 0 012.828 0L20 14m-6-6h.01M6 20h12a2 2 0 002-2V6a2 2 0 00-2-2H6a2 2 0 00-2 2v12a2 2 0 002 2z\'/></svg><p class=\'text-gray-400 text-sm\'>Image</p></div>'" />
                    </div>

                    <!-- Actions bar -->
                    <div class="px-4 pt-3 pb-1">
                        <div class="flex items-center gap-4 mb-2">
                            <?php if ($__raw['isLoggedIn']): ?>
                                <button class="like-btn group <?= !empty($post['user_liked']) ? 'liked' : '' ?>"
                                        onclick="Gallery.toggleLike(<?= (int)$post['id'] ?>, this)">
                                    <svg class="w-6 h-6 transition-colors <?= !empty($post['user_liked']) ? 'fill-ig-red text-ig-red' : 'text-ig-text hover:text-gray-500' ?>"
                                         viewBox="0 0 24 24" stroke="currentColor" stroke-width="2"
                                         fill="<?= !empty($post['user_liked']) ? 'currentColor' : 'none' ?>">
                                        <path stroke-linecap="round" stroke-linejoin="round"
                                              d="M4.318 6.318a4.5 4.5 0 000 6.364L12 20.364l7.682-7.682a4.5 4.5 0 00-6.364-6.364L12 7.636l-1.318-1.318a4.5 4.5 0 00-6.364 0z"/>
                                    </svg>
                                </button>
                            <?php else: ?>
                                <svg class="w-6 h-6 text-ig-text" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2" fill="none">
                                    <path stroke-linecap="round" stroke-linejoin="round"
                                          d="M4.318 6.318a4.5 4.5 0 000 6.364L12 20.364l7.682-7.682a4.5 4.5 0 00-6.364-6.364L12 7.636l-1.318-1.318a4.5 4.5 0 00-6.364 0z"/>
                                </svg>
                            <?php endif; ?>

                            <button class="text-ig-text hover:text-gray-500 transition-colors"
                                    onclick="Gallery.toggleComments(<?= (int)$post['id'] ?>)">
                                <svg class="w-6 h-6" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2">
                                    <path stroke-linecap="round" stroke-linejoin="round"
                                          d="M8 12h.01M12 12h.01M16 12h.01M21 12c0 4.418-4.03 8-9 8a9.863 9.863 0 01-4.255-.949L3 20l1.395-3.72C3.512 15.042 3 13.574 3 12c0-4.418 4.03-8 9-8s9 3.582 9 8z"/>
                                </svg>
                            </button>

                            <!-- Share -->
                            <div class="relative share-dropdown">
                                <button class="text-ig-text hover:text-gray-500 transition-colors"
                                        onclick="Gallery.toggleShare(<?= (int)$post['id'] ?>)">
                                    <svg class="w-6 h-6" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2">
                                        <path stroke-linecap="round" stroke-linejoin="round" d="M12 19l9 2-9-18-9 18 9-2zm0 0v-8"/>
                                    </svg>
                                </button>
                                <div id="share-menu-<?= (int)$post['id'] ?>"
                                     class="hidden absolute left-0 bottom-full mb-2 bg-white border border-ig-border rounded-lg shadow-lg p-1.5 min-w-[180px] z-50">
                                    <?php
                                        $appUrl = $_ENV['APP_URL'] ?? 'http://localhost:8080';
                                        $shareUrl = urlencode($appUrl . htmlspecialchars($post['image_path']));
                                        $shareText = urlencode("Check out this creation on Camagru!");
                                    ?>
                                    <a href="https://twitter.com/intent/tweet?text=<?= $shareText ?>&url=<?= $shareUrl ?>"
                                       target="_blank" rel="noopener"
                                       class="flex items-center gap-2.5 px-3 py-2 rounded-md text-sm text-ig-text hover:bg-ig-bg transition-colors">
                                        <svg class="w-4 h-4" fill="currentColor" viewBox="0 0 24 24"><path d="M18.244 2.25h3.308l-7.227 8.26 8.502 11.24H16.17l-5.214-6.817L4.99 21.75H1.68l7.73-8.835L1.254 2.25H8.08l4.713 6.231zm-1.161 17.52h1.833L7.084 4.126H5.117z"/></svg>
                                        Share on X
                                    </a>
                                    <a href="https://www.facebook.com/sharer/sharer.php?u=<?= $shareUrl ?>"
                                       target="_blank" rel="noopener"
                                       class="flex items-center gap-2.5 px-3 py-2 rounded-md text-sm text-ig-text hover:bg-ig-bg transition-colors">
                                        <svg class="w-4 h-4 text-blue-600" fill="currentColor" viewBox="0 0 24 24"><path d="M24 12.073c0-6.627-5.373-12-12-12s-12 5.373-12 12c0 5.99 4.388 10.954 10.125 11.854v-8.385H7.078v-3.47h3.047V9.43c0-3.007 1.792-4.669 4.533-4.669 1.312 0 2.686.235 2.686.235v2.953H15.83c-1.491 0-1.956.925-1.956 1.874v2.25h3.328l-.532 3.47h-2.796v8.385C19.612 23.027 24 18.062 24 12.073z"/></svg>
                                        Share on Facebook
                                    </a>
                                    <button onclick="Gallery.copyLink('<?= htmlspecialchars($appUrl . $post['image_path']) ?>')"
                                            class="flex items-center gap-2.5 px-3 py-2 rounded-md text-sm text-ig-text hover:bg-ig-bg transition-colors w-full text-left">
                                        <svg class="w-4 h-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2"><path stroke-linecap="round" stroke-linejoin="round" d="M8 16H6a2 2 0 01-2-2V6a2 2 0 012-2h8a2 2 0 012 2v2m-6 12h8a2 2 0 002-2v-8a2 2 0 00-2-2h-8a2 2 0 00-2 2v8a2 2 0 002 2z"/></svg>
                                        Copy Link
                                    </button>
                                </div>
                            </div>
                        </div>

                        <!-- Like count -->
                        <div class="mb-1">
                            <span class="like-count text-sm font-semibold text-ig-text"><?= (int)$post['like_count'] ?> like<?= (int)$post['like_count'] !== 1 ? 's' : '' ?></span>
                        </div>

                        <!-- Author + timestamp -->
                        <div class="mb-1">
                            <span class="text-sm font-semibold text-ig-text"><?= htmlspecialchars($post['author']) ?></span>
                            <span class="text-sm text-ig-text ml-1">shared a creation</span>
                        </div>

                        <!-- View comments link -->
                        <?php if ((int)$post['comment_count'] > 0): ?>
                            <button class="text-sm text-ig-muted mb-1 hover:text-gray-600 transition-colors"
                                    onclick="Gallery.toggleComments(<?= (int)$post['id'] ?>)">
                                View all <?= (int)$post['comment_count'] ?> comment<?= (int)$post['comment_count'] !== 1 ? 's' : '' ?>
                            </button>
                        <?php endif; ?>

                        <!-- Time ago -->
                        <p class="text-[10px] text-ig-muted uppercase tracking-wide mt-1 mb-2">
                            <?php
                                $time = strtotime($post['created_at']);
                                $diff = time() - $time;
                                if ($diff < 60) echo 'Just now';
                                elseif ($diff < 3600) echo (int)($diff / 60) . ' minutes ago';
                                elseif ($diff < 86400) echo (int)($diff / 3600) . ' hours ago';
                                elseif ($diff < 604800) echo (int)($diff / 86400) . ' days ago';
                                else echo date('F j, Y', $time);
                            ?>
                        </p>
                    </div>

                    <!-- Comments section (hidden by default, loaded via AJAX) -->
                    <div id="comments-<?= (int)$post['id'] ?>" class="hidden border-t border-ig-border">
                        <div class="px-4 py-3 space-y-3 max-h-60 overflow-y-auto comments-list">
                            <div class="text-center py-2">
                                <div class="spinner mx-auto"></div>
                            </div>
                        </div>

                        <?php if ($__raw['isLoggedIn']): ?>
                            <form class="px-4 py-3 border-t border-ig-border flex items-center gap-2"
                                  onsubmit="Gallery.addComment(event, <?= (int)$post['id'] ?>)">
                                <svg class="w-6 h-6 text-ig-text flex-shrink-0" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2">
                                    <path stroke-linecap="round" stroke-linejoin="round" d="M14.828 14.828a4 4 0 01-5.656 0M9 10h.01M15 10h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"/>
                                </svg>
                                <input type="text" name="content"
                                       placeholder="Add a comment…"
                                       maxlength="1000"
                                       autocomplete="off"
                                       class="flex-1 bg-transparent border-none text-sm text-ig-text placeholder-ig-muted focus:outline-none py-2" />
                                <button type="submit"
                                        class="text-ig-blue hover:text-blue-700 text-sm font-semibold transition-colors">
                                    Post
                                </button>
                            </form>
                        <?php else: ?>
                            <div class="px-4 py-3 border-t border-ig-border text-center">
                                <a href="/login" class="text-ig-blue hover:text-blue-700 text-sm font-semibold">Log in to add a comment</a>
                            </div>
                        <?php endif; ?>
                    </div>
                </article>
            <?php endforeach; ?>
        </div>

        <!-- ── Pagination ── -->
        <?php if ((int)$__raw['totalPages'] > 1): ?>
            <nav class="flex items-center justify-center gap-2 mt-8" id="pagination">
                <?php $page = (int)$__raw['page']; $total = (int)$__raw['totalPages']; ?>

                <?php if ($page > 1): ?>
                    <a href="?page=<?= $page - 1 ?>"
                       class="px-4 py-2 bg-white border border-ig-border text-ig-text rounded-lg hover:bg-ig-bg transition-colors text-sm font-medium">
                        &larr; Prev
                    </a>
                <?php endif; ?>

                <?php
                    $start = max(1, $page - 2);
                    $end   = min($total, $page + 2);
                ?>
                <?php for ($p = $start; $p <= $end; $p++): ?>
                    <?php if ($p === $page): ?>
                        <span class="px-4 py-2 bg-ig-blue text-white rounded-lg text-sm font-semibold"><?= $p ?></span>
                    <?php else: ?>
                        <a href="?page=<?= $p ?>"
                           class="px-4 py-2 bg-white border border-ig-border text-ig-text rounded-lg hover:bg-ig-bg transition-colors text-sm">
                            <?= $p ?>
                        </a>
                    <?php endif; ?>
                <?php endfor; ?>

                <?php if ($page < $total): ?>
                    <a href="?page=<?= $page + 1 ?>"
                       class="px-4 py-2 bg-white border border-ig-border text-ig-text rounded-lg hover:bg-ig-bg transition-colors text-sm font-medium">
                        Next &rarr;
                    </a>
                <?php endif; ?>
            </nav>
        <?php endif; ?>

    <?php endif; ?>
</div>

<!-- Gallery JavaScript -->
<script src="/assets/js/gallery.js"></script>
