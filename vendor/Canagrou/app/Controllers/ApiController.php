<?php

declare(strict_types=1);

namespace App\Controllers;

use App\Core\Controller;
use App\Core\Csrf;
use App\Core\Session;
use App\Models\User;

/**
 * ApiController — Lightweight endpoints for the Flutter mobile app.
 */
class ApiController extends Controller
{
    /**
     * Return a CSRF token so mobile clients can make POST requests.
     */
    public function csrf(): void
    {
        $this->json(['token' => Csrf::token()]);
    }

    /**
     * Return current authenticated user profile.
     */
    public function me(): void
    {
        if (!Session::isAuthenticated()) {
            $this->json(['authenticated' => false], 401);
            return;
        }

        $user = (new User())->findById($this->userId());
        if (!$user) {
            $this->json(['authenticated' => false], 401);
            return;
        }

        $this->json([
            'authenticated'   => true,
            'id'              => (int)$user['id'],
            'username'        => $user['username'],
            'email'           => $user['email'],
            'notify_comments' => (bool)$user['notify_comments'],
            'created_at'      => $user['created_at'],
        ]);
    }
}
