<?php

declare(strict_types=1);

namespace App\Core;

/**
 * CSRF Protection
 * Generates and validates per-session CSRF tokens.
 */
class Csrf
{
    private const TOKEN_KEY = '_csrf_token';

    /**
     * Generate or retrieve the current CSRF token.
     */
    public static function token(): string
    {
        if (!Session::has(self::TOKEN_KEY)) {
            Session::set(self::TOKEN_KEY, bin2hex(random_bytes(32)));
        }
        return Session::get(self::TOKEN_KEY);
    }

    /**
     * Return an HTML hidden input field for forms.
     */
    public static function field(): string
    {
        $token = htmlspecialchars(self::token(), ENT_QUOTES, 'UTF-8');
        return '<input type="hidden" name="_csrf" value="' . $token . '">';
    }

    /**
     * Validate a submitted token against the session token.
     */
    public static function validate(?string $submittedToken): bool
    {
        $sessionToken = Session::get(self::TOKEN_KEY);
        if ($sessionToken === null || $submittedToken === null) {
            return false;
        }
        return hash_equals($sessionToken, $submittedToken);
    }

    /**
     * Validate and abort with 403 if invalid.
     */
    public static function guard(): void
    {
        $token = $_POST['_csrf'] ?? $_SERVER['HTTP_X_CSRF_TOKEN'] ?? null;
        if (!self::validate($token)) {
            http_response_code(403);
            echo json_encode(['error' => 'Invalid CSRF token']);
            exit;
        }
    }

    /**
     * Regenerate the token (call after successful form submission if desired).
     */
    public static function regenerate(): void
    {
        Session::set(self::TOKEN_KEY, bin2hex(random_bytes(32)));
    }
}
