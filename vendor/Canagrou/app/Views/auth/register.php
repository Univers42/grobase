<?php
use App\Core\Csrf;
use App\Core\Session;

$old = Session::getFlash('old_input') ?? [];
$oldUsername = htmlspecialchars($old['username'] ?? '', ENT_QUOTES, 'UTF-8');
$oldEmail = htmlspecialchars($old['email'] ?? '', ENT_QUOTES, 'UTF-8');
?>

<div class="flex items-center justify-center min-h-[80vh] py-8 px-4">
    <div class="w-full max-w-[350px]">
        <!-- Main Card -->
        <div class="bg-white border border-ig-border rounded-sm px-10 pt-10 pb-6 mb-2.5">
            <!-- Logo -->
            <div class="text-center mb-4">
                <h1 class="text-4xl font-extrabold text-ig-text tracking-tight" style="font-family: 'Inter', sans-serif;">Camagru</h1>
                <p class="text-ig-muted font-semibold text-base mt-3">Sign up to see photos and videos from your friends.</p>
            </div>

            <!-- Form -->
            <form action="/register" method="POST" class="space-y-2 mt-6" id="register-form">
                <?= Csrf::field() ?>

                <!-- Email -->
                <div>
                    <input type="email"
                           id="email"
                           name="email"
                           value="<?= $oldEmail ?>"
                           required
                           autocomplete="email"
                           class="w-full px-3 py-[9px] rounded-[3px] bg-ig-bg border border-ig-border text-ig-text text-xs placeholder-ig-muted focus:outline-none focus:border-gray-400 transition-colors"
                           placeholder="Email">
                </div>

                <!-- Username -->
                <div>
                    <input type="text"
                           id="username"
                           name="username"
                           value="<?= $oldUsername ?>"
                           required
                           minlength="3"
                           maxlength="20"
                           pattern="[a-zA-Z0-9_]+"
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
                           minlength="8"
                           autocomplete="new-password"
                           class="w-full px-3 py-[9px] rounded-[3px] bg-ig-bg border border-ig-border text-ig-text text-xs placeholder-ig-muted focus:outline-none focus:border-gray-400 transition-colors"
                           placeholder="Password">
                    <!-- Password strength indicator -->
                    <div class="flex gap-1 mt-1.5" id="strength-bars">
                        <div class="h-[3px] flex-1 rounded-full bg-gray-200 transition-colors" data-bar="1"></div>
                        <div class="h-[3px] flex-1 rounded-full bg-gray-200 transition-colors" data-bar="2"></div>
                        <div class="h-[3px] flex-1 rounded-full bg-gray-200 transition-colors" data-bar="3"></div>
                        <div class="h-[3px] flex-1 rounded-full bg-gray-200 transition-colors" data-bar="4"></div>
                    </div>
                </div>

                <!-- Confirm Password -->
                <div>
                    <input type="password"
                           id="password_confirm"
                           name="password_confirm"
                           required
                           autocomplete="new-password"
                           class="w-full px-3 py-[9px] rounded-[3px] bg-ig-bg border border-ig-border text-ig-text text-xs placeholder-ig-muted focus:outline-none focus:border-gray-400 transition-colors"
                           placeholder="Confirm Password">
                </div>

                <!-- Terms -->
                <p class="text-[10px] text-ig-muted text-center mt-3 leading-relaxed">
                    By signing up, you agree to the use of webcam capture and creative overlays.
                </p>

                <!-- Submit -->
                <button type="submit"
                        class="w-full py-[7px] rounded-lg font-semibold text-sm text-white bg-ig-blue hover:bg-blue-600 transition-colors mt-2">
                    Sign up
                </button>
            </form>
        </div>

        <!-- Log In Card -->
        <div class="bg-white border border-ig-border rounded-sm px-10 py-5 text-center">
            <p class="text-sm text-ig-text">
                Have an account?
                <a href="/login" class="text-ig-blue font-semibold hover:text-blue-700">Log in</a>
            </p>
        </div>
    </div>
</div>

<script src="/assets/js/auth.js"></script>
