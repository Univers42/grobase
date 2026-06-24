<?php

declare(strict_types=1);

namespace App\Core;

/**
 * Simple PHP template renderer with layout support.
 * Auto-escapes variables for XSS protection.
 */
class View
{
    private static string $layoutsDir = __DIR__ . '/../Views/layouts/';
    private static string $viewsDir   = __DIR__ . '/../Views/';

    /**
     * Render a view inside a layout.
     *
     * @param string $view   View path relative to Views/ (e.g., 'auth/login')
     * @param array  $data   Variables to extract into the view scope
     * @param string $layout Layout name (default: 'main')
     */
    public static function render(string $view, array $data = [], string $layout = 'main'): void
    {
        // Auto-escape all string values in data
        $safeData = self::escapeData($data);

        // Extract variables into scope
        extract($safeData, EXTR_SKIP);

        // Also provide raw data under $__raw for cases where HTML is intentional
        $__raw = $data;

        // Capture view content
        ob_start();
        $viewFile = self::$viewsDir . str_replace('.', '/', $view) . '.php';
        if (!file_exists($viewFile)) {
            ob_end_clean();
            throw new \RuntimeException("View not found: {$view}");
        }
        include $viewFile;
        $__content = ob_get_clean();

        // Render inside layout
        $layoutFile = self::$layoutsDir . $layout . '.php';
        if (!file_exists($layoutFile)) {
            // No layout — output directly
            echo $__content;
            return;
        }

        // Pass page title if set
        $__title = $data['_title'] ?? 'Camagru';

        include $layoutFile;
    }

    /**
     * Render a view without any layout (for partials, emails, etc.).
     */
    public static function partial(string $view, array $data = []): string
    {
        $safeData = self::escapeData($data);
        extract($safeData, EXTR_SKIP);
        $__raw = $data;

        ob_start();
        $viewFile = self::$viewsDir . str_replace('.', '/', $view) . '.php';
        if (!file_exists($viewFile)) {
            ob_end_clean();
            return '';
        }
        include $viewFile;
        return ob_get_clean();
    }

    /**
     * Recursively escape string values in data array.
     */
    private static function escapeData(array $data): array
    {
        $escaped = [];
        foreach ($data as $key => $value) {
            if (is_string($value)) {
                $escaped[$key] = htmlspecialchars($value, ENT_QUOTES, 'UTF-8');
            } elseif (is_array($value)) {
                $escaped[$key] = self::escapeData($value);
            } else {
                $escaped[$key] = $value;
            }
        }
        return $escaped;
    }
}
