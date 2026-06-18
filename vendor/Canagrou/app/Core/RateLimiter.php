<?php

declare(strict_types=1);

namespace App\Core;

/**
 * Session-based Rate Limiter
 * Limits requests per time window to prevent brute-force attacks.
 * Uses session storage (no external dependencies).
 */
class RateLimiter
{
    /**
     * Check if a request is allowed under the rate limit.
     *
     * @param string $key     Unique key for the action (e.g., 'login', 'register')
     * @param int    $maxAttempts  Max attempts allowed in the window
     * @param int    $windowSeconds  Time window in seconds
     * @return bool  True if allowed, false if rate-limited
     */
    public static function check(string $key, int $maxAttempts = 5, int $windowSeconds = 60): bool
    {
        $storeKey = "_rate_limit_{$key}";
        $now = time();

        $data = Session::get($storeKey, ['attempts' => [], 'blocked_until' => 0]);

        // If currently blocked, check if block has expired
        if ($data['blocked_until'] > $now) {
            return false;
        }

        // Clean old attempts outside the window
        $data['attempts'] = array_values(array_filter(
            $data['attempts'],
            fn(int $ts) => ($now - $ts) < $windowSeconds
        ));

        // Check if limit exceeded
        if (count($data['attempts']) >= $maxAttempts) {
            // Block for the remainder of the window
            $data['blocked_until'] = $now + $windowSeconds;
            Session::set($storeKey, $data);
            return false;
        }

        // Record this attempt
        $data['attempts'][] = $now;
        $data['blocked_until'] = 0;
        Session::set($storeKey, $data);

        return true;
    }

    /**
     * Get remaining seconds until the rate limit resets.
     */
    public static function retryAfter(string $key): int
    {
        $storeKey = "_rate_limit_{$key}";
        $data = Session::get($storeKey, ['attempts' => [], 'blocked_until' => 0]);

        if ($data['blocked_until'] > time()) {
            return $data['blocked_until'] - time();
        }

        return 0;
    }

    /**
     * Enforce rate limit — sends 429 for JSON, 302 redirect with flash for forms.
     */
    public static function enforce(string $key, int $maxAttempts = 5, int $windowSeconds = 60): void
    {
        if (!self::check($key, $maxAttempts, $windowSeconds)) {
            $retryAfter = self::retryAfter($key);

            $accept = $_SERVER['HTTP_ACCEPT'] ?? '';
            $isAjax = str_contains($accept, 'application/json')
                   || !empty($_SERVER['HTTP_X_REQUESTED_WITH']);

            if ($isAjax) {
                http_response_code(429);
                header("Retry-After: {$retryAfter}");
                header('Content-Type: application/json; charset=utf-8');
                echo json_encode([
                    'error' => 'Too many requests. Please try again later.',
                    'retry_after' => $retryAfter,
                ]);
            } else {
                Session::flash('error', "Too many attempts. Please wait {$retryAfter} seconds before trying again.");
                // Redirect back with 302 — flash message communicates the rate limit
                $referer = $_SERVER['HTTP_REFERER'] ?? '/';
                // Same-origin check
                $parsed = parse_url($referer);
                $host = $parsed['host'] ?? '';
                $serverHost = $_SERVER['HTTP_HOST'] ?? 'localhost';
                if ($host !== '' && $host !== $serverHost) {
                    $referer = '/';
                }
                header("Location: {$referer}");
            }
            exit;
        }
    }

    /**
     * Reset the rate limit for a key (e.g., after successful login).
     */
    public static function reset(string $key): void
    {
        Session::remove("_rate_limit_{$key}");
    }
}
