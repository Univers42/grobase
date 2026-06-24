<?php

declare(strict_types=1);

namespace App\Controllers;

use App\Core\Controller;
use App\Core\Session;
use App\Models\Like;

/**
 * LikeController — Toggle likes on posts (AJAX only).
 */
class LikeController extends Controller
{
    private Like $like;

    public function __construct()
    {
        $this->like = new Like();
    }

    /**
     * Toggle like on a post. Returns JSON.
     */
    public function toggle(array $params = []): void
    {
        if (!Session::isAuthenticated()) {
            $this->json(['error' => 'You must be logged in to like posts.'], 401);
            return;
        }

        $postId = (int)($params['post_id'] ?? 0);
        if ($postId <= 0) {
            $this->json(['error' => 'Invalid post.'], 400);
            return;
        }

        $result = $this->like->toggle($this->userId(), $postId);

        $this->json([
            'success' => true,
            'liked'   => $result['liked'],
            'count'   => $result['count'],
        ]);
    }
}
