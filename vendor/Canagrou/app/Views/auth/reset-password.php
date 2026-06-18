<?php
use App\Core\Csrf;
?>

<div class="flex items-center justify-center min-h-[80vh] py-8 px-4">
    <div class="w-full max-w-[350px]">
        <div class="bg-white border border-ig-border rounded-sm px-10 pt-10 pb-6 mb-2.5">
            <!-- Icon -->
            <div class="text-center mb-4">
                <div class="w-20 h-20 mx-auto mb-4 border-2 border-ig-text rounded-full flex items-center justify-center">
                    <svg class="w-10 h-10 text-ig-text" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5" d="M15 7a2 2 0 012 2m4 0a6 6 0 01-7.743 5.743L11 17H9v2H7v2H4a1 1 0 01-1-1v-2.586a1 1 0 01.293-.707l5.964-5.964A6 6 0 1121 9z"/>
                    </svg>
                </div>
                <h1 class="text-base font-semibold text-ig-text">Create new password</h1>
                <p class="text-ig-muted text-sm mt-2">Your new password must be different from previously used passwords.</p>
            </div>

            <!-- Form -->
            <form action="/reset-password" method="POST" class="space-y-2 mt-4">
                <?= Csrf::field() ?>
                <input type="hidden" name="token" value="<?= htmlspecialchars($__raw['token'] ?? '', ENT_QUOTES, 'UTF-8') ?>">

                <div>
                    <input type="password"
                           id="password"
                           name="password"
                           required
                           minlength="8"
                           autocomplete="new-password"
                           class="w-full px-3 py-[9px] rounded-[3px] bg-ig-bg border border-ig-border text-ig-text text-xs placeholder-ig-muted focus:outline-none focus:border-gray-400 transition-colors"
                           placeholder="New Password">
                </div>

                <div>
                    <input type="password"
                           id="password_confirm"
                           name="password_confirm"
                           required
                           autocomplete="new-password"
                           class="w-full px-3 py-[9px] rounded-[3px] bg-ig-bg border border-ig-border text-ig-text text-xs placeholder-ig-muted focus:outline-none focus:border-gray-400 transition-colors"
                           placeholder="Confirm New Password">
                </div>

                <button type="submit"
                        class="w-full py-[7px] rounded-lg font-semibold text-sm text-white bg-ig-blue hover:bg-blue-600 transition-colors mt-2">
                    Reset Password
                </button>
            </form>
        </div>

        <div class="bg-white border border-ig-border rounded-sm px-10 py-4 text-center">
            <a href="/login" class="text-sm font-semibold text-ig-text hover:text-gray-600">Back to Login</a>
        </div>
    </div>
</div>
