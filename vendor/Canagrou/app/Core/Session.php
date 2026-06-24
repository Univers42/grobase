<?php

declare(strict_types=1);

namespace App\Core;

/**
 * Session manager with flash message support.
 */
class Session
{
    public static function start(): void
    {
        if (session_status() === PHP_SESSION_NONE) {
            $isSecure = (!empty($_SERVER['HTTPS']) && $_SERVER['HTTPS'] !== 'off')
                     || (int)($_SERVER['SERVER_PORT'] ?? 0) === 443;
            session_set_cookie_params([
                'lifetime' => 0,
                'path'     => '/',
                'secure'   => $isSecure,
                'httponly'  => true,
                'samesite'  => 'Lax',
            ]);
            session_start();
        }
    }

    public static function set(string $key, mixed $value): void
    {
        $_SESSION[$key] = $value;
    }

    public static function get(string $key, mixed $default = null): mixed
    {
        return $_SESSION[$key] ?? $default;
    }

    public static function has(string $key): bool
    {
        return isset($_SESSION[$key]);
    }

    public static function remove(string $key): void
    {
        unset($_SESSION[$key]);
    }

    public static function destroy(): void
    {
        $_SESSION = [];
        if (ini_get('session.use_cookies')) {
            $params = session_get_cookie_params();
            setcookie(
                session_name(),
                '',
                time() - 42000,
                $params['path'],
                $params['domain'],
                $params['secure'],
                $params['httponly']
            );
        }
        session_destroy();
    }

    /**
     * Regenerate session ID (call on login to prevent fixation).
     */
    public static function regenerate(): void
    {
        session_regenerate_id(true);
    }

    /**
     * Set a flash message (available only for next request).
     */
    public static function flash(string $key, mixed $value): void
    {
        $_SESSION['_flash'][$key] = $value;
    }

    /**
     * Get and consume a flash message.
     */
    public static function getFlash(string $key, mixed $default = null): mixed
    {
        $value = $_SESSION['_flash'][$key] ?? $default;
        unset($_SESSION['_flash'][$key]);
        return $value;
    }

    /**
     * Check if a flash message exists.
     */
    public static function hasFlash(string $key): bool
    {
        return isset($_SESSION['_flash'][$key]);
    }

    /**
     * Get the currently logged-in user ID, or null.
     */
    public static function userId(): ?int
    {
        $id = self::get('user_id');
        return $id !== null ? (int)$id : null;
    }

    /**
     * Check if user is authenticated.
     */
    public static function isAuthenticated(): bool
    {
        return self::userId() !== null;
    }
}
