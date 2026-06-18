<?php
use App\Core\Csrf;
?>

<div class="flex items-center justify-center min-h-[80vh] py-8 px-4">
    <div class="w-full max-w-[350px]">
        <!-- Main Card -->
        <div class="bg-white border border-ig-border rounded-sm px-10 pt-10 pb-6 mb-2.5">
            <!-- Lock Icon -->
            <div class="text-center mb-4">
                <div class="w-24 h-24 mx-auto mb-4 border-2 border-ig-text rounded-full flex items-center justify-center">
                    <svg class="w-12 h-12 text-ig-text" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5" d="M12 15v2m-6 4h12a2 2 0 002-2v-6a2 2 0 00-2-2H6a2 2 0 00-2 2v6a2 2 0 002 2zm10-10V7a4 4 0 00-8 0v4h8z"/>
                    </svg>
                </div>
                <h1 class="text-base font-semibold text-ig-text">Trouble logging in?</h1>
                <p class="text-ig-muted text-sm mt-2 leading-relaxed">Enter your email address and we'll send you a link to get back into your account.</p>
            </div>

            <!-- Form -->
            <form action="/forgot-password" method="POST" class="space-y-3 mt-4">
                <?= Csrf::field() ?>

                <!-- Email -->
                <div>
                    <input type="email"
                           id="email"
                           name="email"
                           required
                           autocomplete="email"
                           class="w-full px-3 py-[9px] rounded-[3px] bg-ig-bg border border-ig-border text-ig-text text-xs placeholder-ig-muted focus:outline-none focus:border-gray-400 transition-colors"
                           placeholder="Email">
                </div>

                <!-- Submit -->
                <button type="submit"
                        class="w-full py-[7px] rounded-lg font-semibold text-sm text-white bg-ig-blue hover:bg-blue-600 transition-colors">
                    Send Login Link
                </button>
            </form>

            <!-- Divider -->
            <div class="flex items-center gap-4 my-5">
                <div class="flex-1 h-px bg-ig-border"></div>
                <span class="text-xs font-semibold text-ig-muted uppercase">Or</span>
                <div class="flex-1 h-px bg-ig-border"></div>
            </div>

            <div class="text-center">
                <a href="/register" class="text-sm font-semibold text-ig-text hover:text-gray-600">Create New Account</a>
            </div>
        </div>

        <!-- Back to Login -->
        <div class="bg-white border border-ig-border rounded-sm px-10 py-4 text-center">
            <a href="/login" class="text-sm font-semibold text-ig-text hover:text-gray-600">Back to Login</a>
        </div>
    </div>
</div>
