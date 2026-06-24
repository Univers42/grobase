<?php

declare(strict_types=1);

namespace App\Controllers;

use App\Core\Controller;
use App\Core\Session;
use App\Models\Post;

/**
 * Gallery Controller — Public photo gallery with pagination.
 */
class GalleryController extends Controller
{
    private Post $post;

    public function __construct()
    {
        $this->post = new Post();
    }

    /**
     * Show the public gallery (paginated, 5 per page).
     */
    public function index(array $params = []): void
    {
        $page = max(1, (int)$this->query('page', '1'));
        $perPage = 5;

        $currentUserId = Session::isAuthenticated() ? Session::userId() : null;
        $result = $this->post->findAllWithMeta($page, $perPage, $currentUserId);

        // If AJAX request, return JSON (for infinite scroll bonus)
        if ($this->wantsJson()) {
            // Add time_ago to each post
            $result['data'] = array_map(function ($post) {
                $post['time_ago'] = $this->timeAgo($post['created_at']);
                return $post;
            }, $result['data']);

            $this->json($result);
            return;
        }

        $this->render('gallery/feed', [
            '_title'      => 'Gallery — Camagru',
            'posts'       => $result['data'],
            'page'        => $result['page'],
            'totalPages'  => $result['totalPages'],
            'total'       => $result['total'],
            'isLoggedIn'  => Session::isAuthenticated(),
            'currentUser' => Session::get('username', ''),
        ]);
    }

    /**
     * Human-readable relative time.
     */
    private function timeAgo(string $datetime): string
    {
        $time = strtotime($datetime);
        $diff = time() - $time;

        if ($diff < 60)    return 'Just now';
        if ($diff < 3600)  return (int)($diff / 60) . 'm ago';
        if ($diff < 86400) return (int)($diff / 3600) . 'h ago';
        if ($diff < 604800) return (int)($diff / 86400) . 'd ago';

        return date('M j', $time);
    }
}
