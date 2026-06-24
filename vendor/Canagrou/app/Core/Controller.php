<?php

declare(strict_types=1);

namespace App\Core;

/**
 * Base Controller
 * Provides helper methods for all controllers.
 */
abstract class Controller
{
    /**
     * Render a view with layout.
     */
    protected function render(string $view, array $data = [], string $layout = 'main'): void
    {
        View::render($view, $data, $layout);
    }

    /**
     * Send a JSON response.
     */
    protected function json(mixed $data, int $status = 200): void
    {
        http_response_code($status);
        header('Content-Type: application/json; charset=utf-8');
        echo json_encode($data, JSON_UNESCAPED_UNICODE);
        exit;
    }

    /**
     * Redirect to a URL. Sanitizes to prevent header injection.
     */
    protected function redirect(string $url): void
    {
        // Strip newlines to prevent header injection
        $url = str_replace(["\r", "\n", "\0"], '', $url);
        header("Location: {$url}");
        exit;
    }

    /**
     * Redirect back to the referring page (same-origin only).
     */
    protected function back(): void
    {
        $referer = $_SERVER['HTTP_REFERER'] ?? '/';

        // Validate same-origin to prevent open redirect attacks
        $parsed = parse_url($referer);
        $host = $parsed['host'] ?? '';
        $serverHost = $_SERVER['HTTP_HOST'] ?? 'localhost';

        if ($host !== '' && $host !== $serverHost) {
            $referer = '/';
        }

        $this->redirect($referer);
    }

    /**
     * Require the user to be authenticated, or redirect to login.
     */
    protected function requireAuth(): void
    {
        if (!Session::isAuthenticated()) {
            if ($this->wantsJson()) {
                $this->json(['error' => 'Authentication required.'], 401);
            }
            Session::flash('error', 'Please log in to access this page.');
            $this->redirect('/login');
        }
    }

    /**
     * Get the current authenticated user ID.
     */
    protected function userId(): ?int
    {
        return Session::userId();
    }

    /** Parsed JSON body cache (null = not parsed yet). */
    private ?array $jsonBody = null;

    /**
     * Get a POST parameter, trimmed.
     * Also checks JSON request body for AJAX requests.
     */
    protected function input(string $key, string $default = ''): string
    {
        // First check $_POST
        if (isset($_POST[$key])) {
            return trim($_POST[$key]);
        }

        // Then check JSON body (for AJAX requests with application/json)
        $json = $this->jsonBody();
        if (isset($json[$key])) {
            return is_string($json[$key]) ? trim($json[$key]) : (string)$json[$key];
        }

        return $default;
    }

    /**
     * Parse and cache the JSON request body.
     */
    protected function jsonBody(): array
    {
        if ($this->jsonBody === null) {
            $contentType = $_SERVER['CONTENT_TYPE'] ?? '';
            if (str_contains($contentType, 'application/json')) {
                $raw = file_get_contents('php://input');
                $this->jsonBody = json_decode($raw, true) ?? [];
            } else {
                $this->jsonBody = [];
            }
        }
        return $this->jsonBody;
    }

    /**
     * Get a GET query parameter.
     */
    protected function query(string $key, string $default = ''): string
    {
        return trim($_GET[$key] ?? $default);
    }

    /**
     * Check if request expects JSON (AJAX).
     */
    protected function wantsJson(): bool
    {
        $accept = $_SERVER['HTTP_ACCEPT'] ?? '';
        return str_contains($accept, 'application/json')
            || !empty($_SERVER['HTTP_X_REQUESTED_WITH']);
    }
}
