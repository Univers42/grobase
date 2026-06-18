<?php

/**
 * CAMAGRU — Front Controller
 * 
 * Single entry point for all HTTP requests.
 * Handles: env loading, autoloading, session, routing.
 */

declare(strict_types=1);

// ─── Error Reporting ───────────────────────────────────────────────
// Show errors in development, hide in production
$appEnv = $_ENV['APP_ENV'] ?? getenv('APP_ENV') ?: 'development';
if ($appEnv === 'development') {
    error_reporting(E_ALL);
    ini_set('display_errors', '1');
} else {
    error_reporting(0);
    ini_set('display_errors', '0');
    ini_set('log_errors', '1');
}

// ─── Load Environment Variables ────────────────────────────────────
$envFile = dirname(__DIR__) . '/.env';
if (file_exists($envFile)) {
    $lines = file($envFile, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);
    foreach ($lines as $line) {
        $line = trim($line);
        if ($line === '' || str_starts_with($line, '#')) {
            continue;
        }
        if (str_contains($line, '=')) {
            [$key, $value] = explode('=', $line, 2);
            $key = trim($key);
            $value = trim($value);
            $_ENV[$key] = $value;
            putenv("{$key}={$value}");
        }
    }
}

// ─── PSR-4-like Autoloader ─────────────────────────────────────────
spl_autoload_register(function (string $class): void {
    // Map namespace prefix to directory
    $prefix = 'App\\';
    $baseDir = dirname(__DIR__) . '/app/';

    // Does the class use the namespace prefix?
    $len = strlen($prefix);
    if (strncmp($prefix, $class, $len) !== 0) {
        return;
    }

    // Get the relative class name
    $relativeClass = substr($class, $len);

    // Replace namespace separators with directory separators
    $file = $baseDir . str_replace('\\', '/', $relativeClass) . '.php';

    if (file_exists($file)) {
        require $file;
    }
});

// ─── Session ───────────────────────────────────────────────────────
use App\Core\Session;
use App\Core\Router;
use App\Core\Csrf;

Session::start();

// ─── Routes ────────────────────────────────────────────────────────
$router = new Router();

// CSRF middleware for POST/DELETE requests
$router->addMiddleware(function (string $method, string $uri): void {
    if (in_array($method, ['POST', 'DELETE'])) {
        Csrf::guard();
    }
});

// ── Public routes ──
$router->get('/',                  'GalleryController', 'index');
$router->get('/gallery',          'GalleryController', 'index');

// ── Auth routes ──
$router->get('/login',             'AuthController', 'loginForm');
$router->post('/login',            'AuthController', 'login');
$router->get('/register',          'AuthController', 'registerForm');
$router->post('/register',         'AuthController', 'register');
$router->get('/logout',            'AuthController', 'logout');
$router->get('/verify',            'AuthController', 'verify');
$router->get('/forgot-password',   'AuthController', 'forgotPasswordForm');
$router->post('/forgot-password',  'AuthController', 'forgotPassword');
$router->get('/reset-password',    'AuthController', 'resetPasswordForm');
$router->post('/reset-password',   'AuthController', 'resetPassword');

// ── User routes ──
$router->get('/settings',              'UserController', 'settings');
$router->post('/settings/username',    'UserController', 'updateUsername');
$router->post('/settings/email',       'UserController', 'updateEmail');
$router->post('/settings/password',    'UserController', 'updatePassword');
$router->post('/settings/notifications', 'UserController', 'updateNotifications');

// ── Editor routes ──
$router->get('/editor',            'EditorController', 'index');
$router->post('/editor/capture',   'EditorController', 'capture');
$router->post('/editor/capture-gif', 'EditorController', 'captureGif');
$router->post('/editor/upload',    'EditorController', 'upload');
$router->delete('/editor/delete/{id}', 'EditorController', 'delete');
$router->get('/editor/my-images',  'EditorController', 'myImages');

// ── Like/Comment API routes ──
$router->post('/like/{post_id}',       'LikeController', 'toggle');
$router->post('/comment/{post_id}',    'CommentController', 'store');
$router->get('/comments/{post_id}',    'CommentController', 'index');

// ── Mobile API routes ──
$router->get('/api/csrf',  'ApiController', 'csrf');
$router->get('/api/me',    'ApiController', 'me');
$router->post('/api/settings/username',     'UserController', 'updateUsername');
$router->post('/api/settings/email',        'UserController', 'updateEmail');
$router->post('/api/settings/password',     'UserController', 'updatePassword');
$router->post('/api/settings/notifications','UserController', 'updateNotifications');

// ─── Dispatch ──────────────────────────────────────────────────────
$method = $_SERVER['REQUEST_METHOD'];
$uri    = $_SERVER['REQUEST_URI'];

$router->dispatch($method, $uri);
