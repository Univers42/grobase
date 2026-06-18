<?php
use App\Core\Csrf;
use App\Core\Session;

$old = Session::getFlash('old_input') ?? [];
$oldUsername = htmlspecialchars($old['username'] ?? '', ENT_QUOTES, 'UTF-8');
?>

<div class="flex items-center justify-center min-h-[80vh] py-8 px-4">
    <div class="w-full max-w-[350px]">
        <!-- Main Card -->
        <div class="bg-white border border-ig-border rounded-sm px-10 pt-10 pb-6 mb-2.5">
            <!-- Logo -->
            <div class="text-center mb-6">
                <h1 class="text-4xl font-extrabold text-ig-text tracking-tight" style="font-family: 'Inter', sans-serif;">Camagru</h1>
            </div>

            <!-- Form -->
            <form action="/login" method="POST" class="space-y-2">
                <?= Csrf::field() ?>

                <!-- Username -->
                <div>
                    <input type="text"
                           id="username"
                           name="username"
                           value="<?= $oldUsername ?>"
                           required
                           autocomplete="username"
                           class="w-full px-3 py-[9px] rounded-[3px] bg-ig-bg border border-ig-border text-ig-text text-xs placeholder-ig-muted focus:outline-none focus:border-gray-400 transition-colors"
                           placeholder="Username">
                </div>

                <!-- Password -->
                <div>
                    <input type="password"
                           id="password"
                           name="password"
                           required
                           autocomplete="current-password"
                           class="w-full px-3 py-[9px] rounded-[3px] bg-ig-bg border border-ig-border text-ig-text text-xs placeholder-ig-muted focus:outline-none focus:border-gray-400 transition-colors"
                           placeholder="Password">
                </div>

                <!-- Submit -->
                <button type="submit"
                        class="w-full py-[7px] rounded-lg font-semibold text-sm text-white bg-ig-blue hover:bg-blue-600 transition-colors mt-3">
                    Log In
                </button>
            </form>

            <!-- Divider -->
            <div class="flex items-center gap-4 my-5">
                <div class="flex-1 h-px bg-ig-border"></div>
                <span class="text-xs font-semibold text-ig-muted uppercase">Or</span>
                <div class="flex-1 h-px bg-ig-border"></div>
            </div>

            <!-- Forgot Password -->
            <div class="text-center">
                <a href="/forgot-password" class="text-xs text-ig-dkblue hover:underline">
                    Forgot password?
                </a>
            </div>
        </div>

        <!-- Sign Up Card -->
        <div class="bg-white border border-ig-border rounded-sm px-10 py-5 text-center">
            <p class="text-sm text-ig-text">
                Don't have an account?
                <a href="/register" class="text-ig-blue font-semibold hover:text-blue-700">Sign up</a>
            </p>
        </div>
    </div>
</div>

<script src="/assets/js/auth.js"></script>