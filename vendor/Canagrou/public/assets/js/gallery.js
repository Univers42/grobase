/**
 * CAMAGRU — Gallery Interactions
 * Handles: like toggle, comments load/add, infinite scroll (bonus).
 * Vanilla ES6+ — no frameworks.
 */

'use strict';

const Gallery = {
    /** Cache loaded comment sections to avoid re-fetching. */
    loadedComments: new Set(),

    /**
     * Toggle like on a post via AJAX.
     */
    async toggleLike(postId, btn) {
        try {
            const result = await App.post(`/like/${postId}`);
            if (!result.success) throw result;

            const svg  = btn.querySelector('svg');
            const span = btn.querySelector('.like-count');

            // Update heart icon
            if (result.liked) {
                btn.classList.add('liked');
                svg.setAttribute('fill', 'currentColor');
                svg.classList.remove('text-gray-800', 'hover:text-gray-500');
                svg.classList.add('fill-red-500', 'text-red-500');
            } else {
                btn.classList.remove('liked');
                svg.setAttribute('fill', 'none');
                svg.classList.add('text-gray-800', 'hover:text-gray-500');
                svg.classList.remove('fill-red-500', 'text-red-500');
            }

            // Update like count text next to post
            const article = btn.closest('article');
            const countEl = article ? article.querySelector('.like-count') : span;
            if (countEl) countEl.textContent = `${result.count} like${result.count !== 1 ? 's' : ''}`;

            // Animate
            btn.style.transform = 'scale(1.2)';
            setTimeout(() => btn.style.transform = '', 200);
        } catch (err) {
            if (err.status === 401) {
                window.location.href = '/login';
                return;
            }
            console.error('Like failed:', err);
        }
    },

    /**
     * Toggle comments section visibility and load if needed.
     */
    async toggleComments(postId) {
        const section = document.getElementById(`comments-${postId}`);
        if (!section) return;

        const isHidden = section.classList.contains('hidden');
        section.classList.toggle('hidden');

        // Load comments if first time opening
        if (isHidden && !this.loadedComments.has(postId)) {
            await this.fetchComments(postId);
        }
    },

    /**
     * Fetch comments for a post and render them.
     */
    async fetchComments(postId) {
        const section  = document.getElementById(`comments-${postId}`);
        const listEl   = section.querySelector('.comments-list');

        try {
            const result = await App.request(`/comments/${postId}`);
            this.loadedComments.add(postId);

            if (result.comments.length === 0) {
                listEl.innerHTML = `
                    <p class="text-gray-400 text-sm text-center py-2">No comments yet. Be the first!</p>
                `;
            } else {
                listEl.innerHTML = result.comments.map(c => this.commentHTML(c)).join('');
            }
        } catch (err) {
            listEl.innerHTML = `<p class="text-red-400 text-sm text-center">Failed to load comments.</p>`;
        }
    },

    /**
     * Add a comment via AJAX.
     */
    async addComment(event, postId) {
        event.preventDefault();
        const form  = event.target;
        const input = form.querySelector('input[name="content"]');
        const content = input.value.trim();

        if (!content) return;

        // Disable button while submitting
        const btn = form.querySelector('button[type="submit"]');
        btn.disabled = true;
        btn.textContent = '…';

        try {
            const result = await App.post(`/comment/${postId}`, { content });
            if (!result.success) throw result;

            // Append comment to list
            const section = document.getElementById(`comments-${postId}`);
            const listEl  = section.querySelector('.comments-list');

            // Remove "no comments" message
            const noMsg = listEl.querySelector('p.text-center');
            if (noMsg) noMsg.remove();

            listEl.insertAdjacentHTML('beforeend', this.commentHTML(result.comment));

            // Scroll to new comment
            listEl.scrollTop = listEl.scrollHeight;

            // Update comment count in actions bar
            const article  = document.querySelector(`[data-post-id="${postId}"]`);
            const countSpan = article.querySelector('.comment-count');
            if (countSpan) countSpan.textContent = result.count;

            // Clear input
            input.value = '';
        } catch (err) {
            if (err.status === 401) {
                window.location.href = '/login';
                return;
            }
            alert(err.error || 'Failed to post comment.');
        } finally {
            btn.disabled = false;
            btn.textContent = 'Post';
        }
    },

    /**
     * Render a single comment as HTML.
     */
    commentHTML(c) {
        const author = App.escapeHtml(c.author);
        const content = App.escapeHtml(c.content);
        const timeAgo = App.escapeHtml(c.time_ago);

        return `
            <div class="flex gap-2.5 items-start">
                <div class="w-7 h-7 rounded-full bg-gradient-to-br from-yellow-400 via-pink-500 to-purple-600 p-[2px] flex-shrink-0 mt-0.5">
                    <div class="w-full h-full rounded-full bg-white flex items-center justify-center">
                        <span class="text-[10px] font-semibold text-gray-800">${author.charAt(0).toUpperCase()}</span>
                    </div>
                </div>
                <div class="flex-1 min-w-0">
                    <span class="text-sm"><b>${author}</b> ${content}</span>
                    <p class="text-gray-400 text-xs mt-0.5">${timeAgo}</p>
                </div>
            </div>
        `;
    },

    // ─── Infinite Scroll (Bonus) ───────────────────────────────

    currentPage: 1,
    totalPages: 1,
    isLoading: false,

    /**
     * Initialize infinite scroll if applicable.
     */
    initInfiniteScroll() {
        const pagination = document.getElementById('pagination');
        if (!pagination) return;

        // Read current page info
        const currentPageBtn = pagination.querySelector('.bg-ig-blue, .bg-indigo-600');
        if (currentPageBtn) {
            this.currentPage = parseInt(currentPageBtn.textContent);
        }

        // Get total pages from last page link
        const links = pagination.querySelectorAll('a[href*="page="]');
        if (links.length > 0) {
            const lastLink = links[links.length - 1];
            const match = lastLink.href.match(/page=(\d+)/);
            if (match) {
                const linkPage = parseInt(match[1]);
                this.totalPages = Math.max(this.totalPages, linkPage);
            }
        }

        // Also check if there's a "Next" link
        const nextLink = Array.from(links).find(a => a.textContent.includes('Next'));
        if (nextLink) {
            const match = nextLink.href.match(/page=(\d+)/);
            if (match) {
                this.totalPages = Math.max(this.totalPages, parseInt(match[1]));
            }
        }

        // Hide pagination
        pagination.style.display = 'none';

        // Add scroll listener
        const sentinel = document.createElement('div');
        sentinel.id = 'scroll-sentinel';
        sentinel.className = 'py-8 text-center';
        const feed = document.getElementById('gallery-feed');
        if (feed) {
            feed.after(sentinel);
        }

        // Use IntersectionObserver for efficient scroll detection
        if ('IntersectionObserver' in window) {
            const observer = new IntersectionObserver((entries) => {
                entries.forEach(entry => {
                    if (entry.isIntersecting && !this.isLoading && this.currentPage < this.totalPages) {
                        this.loadMore();
                    }
                });
            }, { rootMargin: '200px' });

            observer.observe(sentinel);
        }
    },

    /**
     * Load next page of posts via AJAX and append.
     */
    async loadMore() {
        if (this.isLoading || this.currentPage >= this.totalPages) return;
        this.isLoading = true;

        const sentinel = document.getElementById('scroll-sentinel');
        sentinel.innerHTML = '<div class="spinner mx-auto"></div>';

        try {
            const nextPage = this.currentPage + 1;
            const result = await App.request(`/gallery?page=${nextPage}`);

            if (result.data && result.data.length > 0) {
                const feed = document.getElementById('gallery-feed');
                result.data.forEach((post, idx) => {
                    feed.insertAdjacentHTML('beforeend', this.postCardHTML(post, idx));
                });

                this.currentPage = nextPage;
                this.totalPages = result.totalPages;
            }

            if (this.currentPage >= this.totalPages) {
                sentinel.innerHTML = '<p class="text-gray-400 text-sm">You\'ve reached the end!</p>';
            } else {
                sentinel.innerHTML = '';
            }
        } catch (err) {
            sentinel.innerHTML = '<p class="text-red-500 text-sm">Failed to load more.</p>';
        } finally {
            this.isLoading = false;
        }
    },

    /**
     * Render a post card from JSON data (for infinite scroll).
     */
    postCardHTML(post, idx) {
        const author = App.escapeHtml(post.author);
        const initial = author.charAt(0).toUpperCase();
        const imagePath = App.escapeHtml(post.image_path);
        const timeAgo = App.escapeHtml(post.time_ago);
        const liked = post.user_liked ? 'liked' : '';
        const heartFill = post.user_liked ? 'currentColor' : 'none';
        const heartClass = post.user_liked
            ? 'fill-red-500 text-red-500'
            : 'text-gray-800 hover:text-gray-500';
        const countClass = post.user_liked ? 'text-red-500' : 'text-gray-800';
        const isLoggedIn = document.querySelector('meta[name="csrf-token"]') !== null;

        const likeBtn = isLoggedIn
            ? `<button class="like-btn group ${liked}"
                       onclick="Gallery.toggleLike(${post.id}, this)">
                   <svg class="w-6 h-6 transition-colors ${heartClass}" viewBox="0 0 24 24"
                        stroke="currentColor" stroke-width="2" fill="${heartFill}">
                       <path stroke-linecap="round" stroke-linejoin="round"
                             d="M4.318 6.318a4.5 4.5 0 000 6.364L12 20.364l7.682-7.682a4.5 4.5 0 00-6.364-6.364L12 7.636l-1.318-1.318a4.5 4.5 0 00-6.364 0z"/>
                   </svg>
               </button>`
            : `<svg class="w-6 h-6 text-gray-800" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2" fill="none">
                   <path stroke-linecap="round" stroke-linejoin="round"
                         d="M4.318 6.318a4.5 4.5 0 000 6.364L12 20.364l7.682-7.682a4.5 4.5 0 00-6.364-6.364L12 7.636l-1.318-1.318a4.5 4.5 0 00-6.364 0z"/>
               </svg>`;

        const commentForm = isLoggedIn
            ? `<form class="px-4 py-3 border-t border-gray-200 flex items-center gap-2"
                     onsubmit="Gallery.addComment(event, ${post.id})">
                   <input type="text" name="content" placeholder="Add a comment…" maxlength="1000" autocomplete="off"
                          class="flex-1 bg-transparent border-none text-sm text-gray-800 placeholder-gray-400 focus:outline-none py-2" />
                   <button type="submit" class="text-blue-500 hover:text-blue-700 text-sm font-semibold transition-colors">Post</button>
               </form>`
            : `<div class="px-4 py-3 border-t border-gray-200 text-center">
                   <a href="/login" class="text-blue-500 hover:text-blue-700 text-sm font-semibold">Log in to add a comment</a>
               </div>`;

        return `
            <article class="bg-white border border-gray-200 rounded-lg overflow-hidden fade-in-up"
                     data-post-id="${parseInt(post.id)}" style="animation-delay: ${idx * 0.08}s">
                <div class="flex items-center gap-3 px-4 py-3">
                    <div class="w-8 h-8 rounded-full bg-gradient-to-br from-yellow-400 via-pink-500 to-purple-600 p-[2px] flex-shrink-0">
                        <div class="w-full h-full rounded-full bg-white flex items-center justify-center">
                            <span class="text-xs font-semibold text-gray-800">${initial}</span>
                        </div>
                    </div>
                    <span class="text-sm font-semibold text-gray-800">${author}</span>
                </div>
                <div class="bg-gray-50 aspect-square relative overflow-hidden">
                    <img src="${imagePath}" alt="Creation by ${author}" class="w-full h-full object-cover" loading="lazy" />
                </div>
                <div class="px-4 pt-3 pb-1">
                    <div class="flex items-center gap-4 mb-2">
                        ${likeBtn}
                        <button class="text-gray-800 hover:text-gray-500 transition-colors"
                                onclick="Gallery.toggleComments(${post.id})">
                            <svg class="w-6 h-6" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2">
                                <path stroke-linecap="round" stroke-linejoin="round" d="M8 12h.01M12 12h.01M16 12h.01M21 12c0 4.418-4.03 8-9 8a9.863 9.863 0 01-4.255-.949L3 20l1.395-3.72C3.512 15.042 3 13.574 3 12c0-4.418 4.03-8 9-8s9 3.582 9 8z"/>
                            </svg>
                        </button>
                    </div>
                    <div class="mb-1"><span class="like-count text-sm font-semibold text-gray-800">${post.like_count} like${post.like_count !== 1 ? 's' : ''}</span></div>
                    <div class="mb-1"><span class="text-sm font-semibold text-gray-800">${author}</span> <span class="text-sm">shared a creation</span></div>
                    <p class="text-[10px] text-gray-400 uppercase tracking-wide mt-1 mb-2">${timeAgo}</p>
                </div>
                <div id="comments-${post.id}" class="hidden border-t border-gray-200">
                    <div class="px-4 py-3 space-y-3 max-h-60 overflow-y-auto comments-list">
                        <div class="text-center py-2"><div class="spinner mx-auto"></div></div>
                    </div>
                    ${commentForm}
                </div>
            </article>
        `;
    },

    /**
     * Initialize gallery.
     */
    init() {
        this.initInfiniteScroll();

        // Close share menus when clicking outside
        document.addEventListener('click', (e) => {
            if (!e.target.closest('.share-dropdown')) {
                document.querySelectorAll('[id^="share-menu-"]').forEach(m => m.classList.add('hidden'));
            }
        });
    },

    /**
     * Toggle share dropdown for a post.
     */
    toggleShare(postId) {
        const menu = document.getElementById(`share-menu-${postId}`);
        if (!menu) return;

        // Close all other menus
        document.querySelectorAll('[id^="share-menu-"]').forEach(m => {
            if (m !== menu) m.classList.add('hidden');
        });

        menu.classList.toggle('hidden');
    },

    /**
     * Copy image link to clipboard.
     */
    async copyLink(url) {
        try {
            await navigator.clipboard.writeText(url);
            // Brief visual feedback
            const btn = event.target.closest('button');
            const originalText = btn.textContent.trim();
            btn.innerHTML = btn.innerHTML.replace('Copy Link', 'Copied!');
            setTimeout(() => {
                btn.innerHTML = btn.innerHTML.replace('Copied!', 'Copy Link');
            }, 2000);
        } catch (err) {
            // Fallback for older browsers
            const input = document.createElement('input');
            input.value = url;
            document.body.appendChild(input);
            input.select();
            document.execCommand('copy');
            document.body.removeChild(input);
        }

        // Close the menu
        document.querySelectorAll('[id^="share-menu-"]').forEach(m => m.classList.add('hidden'));
    }
};

// Boot
document.addEventListener('DOMContentLoaded', () => Gallery.init());
