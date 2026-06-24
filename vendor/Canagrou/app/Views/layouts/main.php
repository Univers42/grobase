<?php
/**
 * Main Layout — Instagram-style wrapping layout.
 * Variables: $__content (page HTML), $__title (page title)
 */

use App\Core\Session;
use App\Core\Csrf;

$isAuth = Session::isAuthenticated();
$currentUser = $isAuth ? Session::get('username', '') : '';
$currentPath = parse_url($_SERVER['REQUEST_URI'] ?? '/', PHP_URL_PATH);
?>
<!DOCTYPE html>
<html lang="en" class="scroll-smooth">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title><?= htmlspecialchars($__title ?? 'Camagru', ENT_QUOTES, 'UTF-8') ?></title>

    <!-- Google Fonts — Inter -->
    <link rel="preconnect" href="https://fonts.googleapis.com">
    <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
    <link href="https://fonts.googleapis.com/css2?family=Inter:wght@300;400;500;600;700;800;900&display=swap" rel="stylesheet">

    <!-- Tailwind CSS (CDN play mode) -->
    <script src="https://cdn.tailwindcss.com"></script>
    <script>
        tailwind.config = {
            theme: {
                extend: {
                    colors: {
                        ig: {
                            blue:    '#0095f6',
                            dkblue:  '#00376b',
                            red:     '#ed4956',
                            bg:      '#fafafa',
                            border:  '#dbdbdb',
                            text:    '#262626',
                            muted:   '#8e8e8e',
                            card:    '#ffffff',
                        }
                    },
                    fontFamily: {
                        sans: ['Inter', 'system-ui', '-apple-system', 'BlinkMacSystemFont', '"Segoe UI"', 'Roboto', 'sans-serif'],
                    },
                    boxShadow: {
                        'card': '0 0 0 1px rgba(0,0,0,0.0975), 0 1px 2px rgba(0,0,0,0.1)',
                        'card-hover': '0 0 0 1px rgba(0,0,0,0.0975), 0 4px 12px rgba(0,0,0,0.15)',
                    }
                }
            }
        }
    </script>

    <!-- Custom CSS -->
    <link rel="stylesheet" href="/assets/css/app.css">

    <!-- CSRF meta tag for JavaScript AJAX calls -->
    <meta name="csrf-token" content="<?= htmlspecialchars(Csrf::token(), ENT_QUOTES, 'UTF-8') ?>">
</head>
<body class="min-h-screen bg-ig-bg text-ig-text flex flex-col font-sans">

    <!-- ═══ HEADER / NAVBAR ═══ -->
    <header class="sticky top-0 z-50 bg-white border-b border-ig-border">
        <nav class="max-w-[935px] mx-auto px-4 h-[60px] flex items-center justify-between">
            <!-- Logo -->
            <a href="/" class="flex items-center gap-2 group flex-shrink-0">
                <svg class="w-7 h-7" viewBox="0 0 24 24" fill="none">
                    <defs>
                        <linearGradient id="ig-grad" x1="0%" y1="100%" x2="100%" y2="0%">
                            <stop offset="0%" style="stop-color:#feda75"/>
                            <stop offset="25%" style="stop-color:#fa7e1e"/>
                            <stop offset="50%" style="stop-color:#d62976"/>
                            <stop offset="75%" style="stop-color:#962fbf"/>
                            <stop offset="100%" style="stop-color:#4f5bd5"/>
                        </linearGradient>
                    </defs>
                    <rect x="2" y="2" width="20" height="20" rx="6" stroke="url(#ig-grad)" stroke-width="2" fill="none"/>
                    <circle cx="12" cy="12" r="5" stroke="url(#ig-grad)" stroke-width="2" fill="none"/>
                    <circle cx="18" cy="6" r="1.5" fill="url(#ig-grad)"/>
                </svg>
                <span class="text-xl font-bold text-ig-text hidden sm:block" style="font-family: 'Inter', sans-serif; letter-spacing: -0.5px;">
                    Camagru
                </span>
            </a>

            <!-- Search (desktop) -->
            <div class="hidden md:block flex-1 max-w-[268px] mx-8">
                <div class="relative">
                    <svg class="absolute left-3 top-1/2 -translate-y-1/2 w-4 h-4 text-ig-muted" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M21 21l-6-6m2-5a7 7 0 11-14 0 7 7 0 0114 0z"/>
                    </svg>
                    <input type="text" placeholder="Search" disabled
                           class="w-full bg-ig-bg border border-ig-border rounded-lg pl-10 pr-4 py-[7px] text-sm text-ig-text placeholder-ig-muted focus:outline-none focus:border-gray-400">
                </div>
            </div>

            <!-- Navigation Icons -->
            <div class="flex items-center gap-5">
                <!-- Home -->
                <a href="/" class="text-ig-text hover:opacity-60 transition-opacity" title="Home">
                    <?php if ($currentPath === '/' || $currentPath === '/gallery'): ?>
                        <svg class="w-6 h-6" viewBox="0 0 24 24" fill="currentColor"><path d="M9.005 16.545a2.997 2.997 0 012.997-2.997A2.997 2.997 0 0115 16.545V22h7V11.543L12 2 2 11.543V22h7.005z"/></svg>
                    <?php else: ?>
                        <svg class="w-6 h-6" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2"><path stroke-linecap="round" stroke-linejoin="round" d="M3 12l2-2m0 0l7-7 7 7M5 10v10a1 1 0 001 1h3m10-11l2 2m-2-2v10a1 1 0 01-1 1h-3m-6 0a1 1 0 001-1v-4a1 1 0 011-1h2a1 1 0 011 1v4a1 1 0 001 1m-6 0h6"/></svg>
                    <?php endif; ?>
                </a>

                <?php if ($isAuth): ?>
                    <!-- Create / Editor -->
                    <a href="/editor" class="text-ig-text hover:opacity-60 transition-opacity" title="Create">
                        <?php if ($currentPath === '/editor'): ?>
                            <svg class="w-6 h-6" viewBox="0 0 24 24" fill="currentColor"><path fill-rule="evenodd" d="M2 12c0-5.523 4.477-10 10-10s10 4.477 10 10-4.477 10-10 10S2 17.523 2 12zm10-5.5a.75.75 0 01.75.75v4h4a.75.75 0 010 1.5h-4v4a.75.75 0 01-1.5 0v-4h-4a.75.75 0 010-1.5h4v-4A.75.75 0 0112 6.5z" clip-rule="evenodd"/></svg>
                        <?php else: ?>
                            <svg class="w-6 h-6" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2"><path stroke-linecap="round" stroke-linejoin="round" d="M12 9v3m0 0v3m0-3h3m-3 0H9m12 0a9 9 0 11-18 0 9 9 0 0118 0z"/></svg>
                        <?php endif; ?>
                    </a>

                    <!-- Profile dropdown -->
                    <div class="relative" id="profile-dropdown">
                        <button onclick="document.getElementById('profile-menu').classList.toggle('hidden')"
                                class="w-7 h-7 rounded-full bg-gradient-to-br from-yellow-400 via-pink-500 to-purple-600 p-[2px] hover:opacity-80 transition-opacity flex-shrink-0 <?= $currentPath === '/settings' ? 'ring-2 ring-ig-text ring-offset-1' : '' ?>">
                            <div class="w-full h-full rounded-full bg-white flex items-center justify-center">
                                <span class="text-xs font-semibold text-ig-text"><?= strtoupper(substr(htmlspecialchars($currentUser, ENT_QUOTES, 'UTF-8'), 0, 1)) ?></span>
                            </div>
                        </button>
                        <div id="profile-menu" class="hidden absolute right-0 top-full mt-2 bg-white rounded-lg shadow-lg border border-ig-border py-2 min-w-[200px] z-50">
                            <div class="px-4 py-2 border-b border-ig-border">
                                <p class="font-semibold text-sm"><?= htmlspecialchars($currentUser, ENT_QUOTES, 'UTF-8') ?></p>
                            </div>
                            <a href="/settings" class="flex items-center gap-3 px-4 py-2.5 text-sm text-ig-text hover:bg-ig-bg transition-colors">
                                <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M10.325 4.317c.426-1.756 2.924-1.756 3.35 0a1.724 1.724 0 002.573 1.066c1.543-.94 3.31.826 2.37 2.37a1.724 1.724 0 001.066 2.573c1.756.426 1.756 2.924 0 3.35a1.724 1.724 0 00-1.066 2.573c.94 1.543-.826 3.31-2.37 2.37a1.724 1.724 0 00-2.573 1.066c-.426 1.756-2.924 1.756-3.35 0a1.724 1.724 0 00-2.573-1.066c-1.543.94-3.31-.826-2.37-2.37a1.724 1.724 0 00-1.066-2.573c-1.756-.426-1.756-2.924 0-3.35a1.724 1.724 0 001.066-2.573c-.94-1.543.826-3.31 2.37-2.37.996.608 2.296.07 2.572-1.065z"/><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 12a3 3 0 11-6 0 3 3 0 016 0z"/></svg>
                                Settings
                            </a>
                            <hr class="my-1 border-ig-border">
                            <a href="/logout" class="flex items-center gap-3 px-4 py-2.5 text-sm text-red-500 hover:bg-red-50 transition-colors">
                                <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M17 16l4-4m0 0l-4-4m4 4H7m6 4v1a3 3 0 01-3 3H6a3 3 0 01-3-3V7a3 3 0 013-3h4a3 3 0 013 3v1"/></svg>
                                Log Out
                            </a>
                        </div>
                    </div>
                <?php else: ?>
                    <a href="/login"
                       class="px-4 py-[6px] rounded-lg text-sm font-semibold text-white bg-ig-blue hover:bg-blue-600 transition-colors">
                        Log In
                    </a>
                    <a href="/register"
                       class="hidden sm:block text-sm font-semibold text-ig-blue hover:text-ig-dkblue transition-colors">
                        Sign Up
                    </a>
                <?php endif; ?>
            </div>
        </nav>
    </header>

    <!-- ═══ FLASH MESSAGES ═══ -->
    <?php $flashSuccess = Session::getFlash('success'); ?>
    <?php $flashError = Session::getFlash('error'); ?>
    <?php if ($flashSuccess): ?>
        <div class="max-w-[935px] mx-auto px-4 mt-4">
            <div class="bg-green-50 border border-green-200 text-green-700 px-4 py-3 rounded-lg text-sm flex items-center gap-2" role="alert">
                <svg class="w-5 h-5 flex-shrink-0" fill="currentColor" viewBox="0 0 20 20"><path fill-rule="evenodd" d="M10 18a8 8 0 100-16 8 8 0 000 16zm3.707-9.293a1 1 0 00-1.414-1.414L9 10.586 7.707 9.293a1 1 0 00-1.414 1.414l2 2a1 1 0 001.414 0l4-4z" clip-rule="evenodd"/></svg>
                <?= htmlspecialchars($flashSuccess, ENT_QUOTES, 'UTF-8') ?>
            </div>
        </div>
    <?php endif; ?>
    <?php if ($flashError): ?>
        <div class="max-w-[935px] mx-auto px-4 mt-4">
            <div class="bg-red-50 border border-red-200 text-red-600 px-4 py-3 rounded-lg text-sm flex items-center gap-2" role="alert">
                <svg class="w-5 h-5 flex-shrink-0" fill="currentColor" viewBox="0 0 20 20"><path fill-rule="evenodd" d="M10 18a8 8 0 100-16 8 8 0 000 16zM8.707 7.293a1 1 0 00-1.414 1.414L8.586 10l-1.293 1.293a1 1 0 101.414 1.414L10 11.414l1.293 1.293a1 1 0 001.414-1.414L11.414 10l1.293-1.293a1 1 0 00-1.414-1.414L10 8.586 8.707 7.293z" clip-rule="evenodd"/></svg>
                <?= htmlspecialchars($flashError, ENT_QUOTES, 'UTF-8') ?>
            </div>
        </div>
    <?php endif; ?>

    <!-- ═══ MAIN CONTENT ═══ -->
    <main class="flex-1 w-full">
        <?= $__content ?>
    </main>

    <!-- ═══ FOOTER ═══ -->
    <footer class="mt-auto border-t border-ig-border bg-white">
        <div class="max-w-[935px] mx-auto px-4 py-8">
            <div class="flex flex-wrap items-center justify-center gap-x-4 gap-y-1 text-xs text-ig-muted mb-4">
                <a href="/" class="hover:underline">Home</a>
                <a href="/gallery" class="hover:underline">Gallery</a>
                <?php if ($isAuth): ?>
                    <a href="/editor" class="hover:underline">Editor</a>
                    <a href="/settings" class="hover:underline">Settings</a>
                <?php else: ?>
                    <a href="/login" class="hover:underline">Log In</a>
                    <a href="/register" class="hover:underline">Sign Up</a>
                <?php endif; ?>
            </div>
            <p class="text-xs text-ig-muted text-center">
                &copy; <?= date('Y') ?> Camagru — A 42 School Project
            </p>
        </div>
    </footer>

    <!-- Close profile menu when clicking outside -->
    <script>
    document.addEventListener('click', function(e) {
        const dd = document.getElementById('profile-dropdown');
        const menu = document.getElementById('profile-menu');
        if (dd && menu && !dd.contains(e.target)) {
            menu.classList.add('hidden');
        }
    });
    </script>

    <!-- ═══ SCRIPTS ═══ -->
    <script src="/assets/js/app.js"></script>
</body>
</html>
