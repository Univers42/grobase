<?php
use App\Core\Csrf;
use App\Core\Session;

$u = $__raw['user'] ?? [];
?>

<div class="max-w-[935px] mx-auto px-4 py-6 md:py-8">

    <div class="flex flex-col md:flex-row gap-8">
        <!-- Sidebar nav -->
        <aside class="md:w-[236px] flex-shrink-0">
            <div class="bg-white border border-ig-border rounded-lg overflow-hidden">
                <a href="#profile" class="block px-6 py-3 text-sm font-medium text-ig-text bg-ig-bg border-l-2 border-ig-text">
                    Edit Profile
                </a>
                <a href="#security" class="block px-6 py-3 text-sm text-ig-text hover:bg-ig-bg border-l-2 border-transparent transition-colors">
                    Change Password
                </a>
                <a href="#notifications" class="block px-6 py-3 text-sm text-ig-text hover:bg-ig-bg border-l-2 border-transparent transition-colors">
                    Notifications
                </a>
            </div>
        </aside>

        <!-- Content -->
        <div class="flex-1 space-y-8">

            <!-- ═══ PROFILE SECTION ═══ -->
            <section id="profile" class="bg-white border border-ig-border rounded-lg p-6 md:p-8 space-y-6">
                <!-- Profile header -->
                <div class="flex items-center gap-4 pb-6 border-b border-ig-border">
                    <div class="w-10 h-10 rounded-full bg-gradient-to-br from-yellow-400 via-pink-500 to-purple-600 p-[2px] flex-shrink-0">
                        <div class="w-full h-full rounded-full bg-white flex items-center justify-center">
                            <span class="text-sm font-semibold text-ig-text"><?= strtoupper(substr(htmlspecialchars($u['username'] ?? '', ENT_QUOTES, 'UTF-8'), 0, 1)) ?></span>
                        </div>
                    </div>
                    <div>
                        <h2 class="text-lg font-normal text-ig-text"><?= htmlspecialchars($u['username'] ?? '', ENT_QUOTES, 'UTF-8') ?></h2>
                    </div>
                </div>

                <!-- Update Username -->
                <form action="/settings/username" method="POST" class="space-y-4">
                    <?= Csrf::field() ?>
                    <div class="grid grid-cols-1 md:grid-cols-[100px_1fr] gap-2 items-start">
                        <label for="username" class="text-sm font-semibold text-ig-text md:text-right md:pt-2">Username</label>
                        <div>
                            <input type="text" id="username" name="username"
                                   value="<?= htmlspecialchars($u['username'] ?? '', ENT_QUOTES, 'UTF-8') ?>"
                                   required minlength="3" maxlength="20"
                                   class="w-full px-3 py-[7px] rounded-[3px] bg-white border border-ig-border text-ig-text text-sm focus:outline-none focus:border-gray-400 transition-colors">
                            <button type="submit" class="mt-3 px-6 py-[5px] rounded-lg font-semibold text-sm text-white bg-ig-blue hover:bg-blue-600 transition-colors">
                                Submit
                            </button>
                        </div>
                    </div>
                </form>

                <!-- Update Email -->
                <form action="/settings/email" method="POST" class="space-y-4 pt-4 border-t border-ig-border">
                    <?= Csrf::field() ?>
                    <div class="grid grid-cols-1 md:grid-cols-[100px_1fr] gap-2 items-start">
                        <label for="email" class="text-sm font-semibold text-ig-text md:text-right md:pt-2">Email</label>
                        <div>
                            <input type="email" id="email" name="email"
                                   value="<?= htmlspecialchars($u['email'] ?? '', ENT_QUOTES, 'UTF-8') ?>"
                                   required
                                   class="w-full px-3 py-[7px] rounded-[3px] bg-white border border-ig-border text-ig-text text-sm focus:outline-none focus:border-gray-400 transition-colors">
                            <?php if (!($u['verified'] ?? false)): ?>
                                <p class="text-amber-500 text-xs mt-1.5 flex items-center gap-1">
                                    <svg class="w-3.5 h-3.5" fill="currentColor" viewBox="0 0 20 20"><path fill-rule="evenodd" d="M8.257 3.099c.765-1.36 2.722-1.36 3.486 0l5.58 9.92c.75 1.334-.213 2.98-1.742 2.98H4.42c-1.53 0-2.493-1.646-1.743-2.98l5.58-9.92zM11 13a1 1 0 11-2 0 1 1 0 012 0zm-1-8a1 1 0 00-1 1v3a1 1 0 002 0V6a1 1 0 00-1-1z" clip-rule="evenodd"/></svg>
                                    Not verified. Check your inbox for a confirmation email.
                                </p>
                            <?php endif; ?>
                            <button type="submit" class="mt-3 px-6 py-[5px] rounded-lg font-semibold text-sm text-white bg-ig-blue hover:bg-blue-600 transition-colors">
                                Submit
                            </button>
                        </div>
                    </div>
                </form>
            </section>

            <!-- ═══ SECURITY SECTION ═══ -->
            <section id="security" class="bg-white border border-ig-border rounded-lg p-6 md:p-8">
                <h2 class="text-lg font-semibold text-ig-text mb-6">Change Password</h2>
                <form action="/settings/password" method="POST" class="space-y-4">
                    <?= Csrf::field() ?>
                    <div class="grid grid-cols-1 md:grid-cols-[120px_1fr] gap-2 items-start">
                        <label for="current_password" class="text-sm font-semibold text-ig-text md:text-right md:pt-2">Old Password</label>
                        <input type="password" id="current_password" name="current_password" required autocomplete="current-password"
                               class="w-full px-3 py-[7px] rounded-[3px] bg-white border border-ig-border text-ig-text text-sm focus:outline-none focus:border-gray-400 transition-colors"
                               placeholder="Enter current password">
                    </div>
                    <div class="grid grid-cols-1 md:grid-cols-[120px_1fr] gap-2 items-start">
                        <label for="password" class="text-sm font-semibold text-ig-text md:text-right md:pt-2">New Password</label>
                        <input type="password" id="password" name="password" required minlength="8" autocomplete="new-password"
                               class="w-full px-3 py-[7px] rounded-[3px] bg-white border border-ig-border text-ig-text text-sm focus:outline-none focus:border-gray-400 transition-colors"
                               placeholder="Min 8 chars, uppercase, digit, special">
                    </div>
                    <div class="grid grid-cols-1 md:grid-cols-[120px_1fr] gap-2 items-start">
                        <label for="password_confirm" class="text-sm font-semibold text-ig-text md:text-right md:pt-2">Confirm New</label>
                        <div>
                            <input type="password" id="password_confirm" name="password_confirm" required autocomplete="new-password"
                                   class="w-full px-3 py-[7px] rounded-[3px] bg-white border border-ig-border text-ig-text text-sm focus:outline-none focus:border-gray-400 transition-colors"
                                   placeholder="Repeat new password">
                            <button type="submit" class="mt-4 px-6 py-[5px] rounded-lg font-semibold text-sm text-white bg-ig-blue hover:bg-blue-600 transition-colors">
                                Change Password
                            </button>
                        </div>
                    </div>
                </form>
            </section>

            <!-- ═══ NOTIFICATIONS SECTION ═══ -->
            <section id="notifications" class="bg-white border border-ig-border rounded-lg p-6 md:p-8">
                <h2 class="text-lg font-semibold text-ig-text mb-6">Email Notifications</h2>
                <form action="/settings/notifications" method="POST" class="space-y-4">
                    <?= Csrf::field() ?>
                    <label class="flex items-start gap-3 cursor-pointer">
                        <input type="checkbox"
                               name="notify_comments"
                               <?= ($u['notify_comments'] ?? 1) ? 'checked' : '' ?>
                               class="mt-1 w-4 h-4 rounded border-ig-border text-ig-blue focus:ring-ig-blue focus:ring-offset-0">
                        <div>
                            <span class="text-sm font-semibold text-ig-text">Comment notifications</span>
                            <p class="text-ig-muted text-sm">Receive an email when someone comments on your photos</p>
                        </div>
                    </label>
                    <button type="submit" class="px-6 py-[5px] rounded-lg font-semibold text-sm text-white bg-ig-blue hover:bg-blue-600 transition-colors">
                        Save
                    </button>
                </form>
            </section>

        </div>
    </div>
</div>
