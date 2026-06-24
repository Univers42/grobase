<?php

declare(strict_types=1);

namespace App\Core;

/**
 * Lightweight URL Router
 * Maps HTTP method + URI pattern to controller@action.
 * Supports named parameters like {id} in routes.
 */
class Router
{
    private array $routes = [];
    private array $middleware = [];

    /**
     * Register a GET route.
     */
    public function get(string $path, string $controller, string $action): self
    {
        return $this->addRoute('GET', $path, $controller, $action);
    }

    /**
     * Register a POST route.
     */
    public function post(string $path, string $controller, string $action): self
    {
        return $this->addRoute('POST', $path, $controller, $action);
    }

    /**
     * Register a DELETE route.
     */
    public function delete(string $path, string $controller, string $action): self
    {
        return $this->addRoute('DELETE', $path, $controller, $action);
    }

    /**
     * Add global middleware (called on every request).
     */
    public function addMiddleware(callable $middleware): self
    {
        $this->middleware[] = $middleware;
        return $this;
    }

    /**
     * Dispatch the current request.
     */
    public function dispatch(string $method, string $uri): void
    {
        // Support _method override for DELETE via POST forms
        if ($method === 'POST' && isset($_POST['_method'])) {
            $method = strtoupper($_POST['_method']);
        }

        // Treat HEAD requests as GET (standard HTTP behavior)
        $isHead = ($method === 'HEAD');
        if ($isHead) {
            $method = 'GET';
        }

        // Strip query string and trailing slash
        $uri = parse_url($uri, PHP_URL_PATH);
        $uri = rtrim($uri, '/') ?: '/';

        // Run global middleware
        foreach ($this->middleware as $mw) {
            $mw($method, $uri);
        }

        // Match route
        foreach ($this->routes as $route) {
            if ($route['method'] !== $method) {
                continue;
            }

            $pattern = $this->convertToRegex($route['path']);
            if (preg_match($pattern, $uri, $matches)) {
                // Extract named parameters
                $params = array_filter($matches, 'is_string', ARRAY_FILTER_USE_KEY);

                $controllerClass = "App\\Controllers\\{$route['controller']}";
                if (!class_exists($controllerClass)) {
                    $this->sendError(500, "Controller {$route['controller']} not found");
                    return;
                }

                $controller = new $controllerClass();
                $action = $route['action'];

                if (!method_exists($controller, $action)) {
                    $this->sendError(500, "Action {$action} not found");
                    return;
                }

                $controller->$action($params);
                return;
            }
        }

        // No route matched → 404
        $this->sendError(404);
    }

    private function addRoute(string $method, string $path, string $controller, string $action): self
    {
        $this->routes[] = [
            'method'     => $method,
            'path'       => $path,
            'controller' => $controller,
            'action'     => $action,
        ];
        return $this;
    }

    /**
     * Convert route path with {param} placeholders to regex.
     * Example: /gallery/{id} → #^/gallery/(?P<id>[^/]+)$#
     */
    private function convertToRegex(string $path): string
    {
        $pattern = preg_replace('/\{([a-zA-Z_]+)\}/', '(?P<$1>[^/]+)', $path);
        return '#^' . $pattern . '$#';
    }

    private function sendError(int $code, string $message = ''): void
    {
        http_response_code($code);
        if ($code === 404) {
            $errorView = __DIR__ . '/../Views/errors/404.php';
            if (file_exists($errorView)) {
                include $errorView;
            } else {
                echo '<h1>404 — Not Found</h1>';
            }
        } elseif ($code === 403) {
            $errorView = __DIR__ . '/../Views/errors/403.php';
            if (file_exists($errorView)) {
                include $errorView;
            } else {
                echo '<h1>403 — Forbidden</h1>';
            }
        } else {
            echo "<h1>Error {$code}</h1><p>" . htmlspecialchars($message, ENT_QUOTES, 'UTF-8') . "</p>";
        }
    }
}
