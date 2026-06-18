<?php

declare(strict_types=1);

namespace App\Controllers;

use App\Core\Controller;
use App\Core\Session;
use App\Core\Mailer;
use App\Core\Validator;
use App\Models\Comment;
use App\Models\Post;
use App\Models\User;

/**
 * CommentController — Add and list comments on posts.
 */
class CommentController extends Controller
{
    private Comment $comment;
    private Post $post;
    private User $user;

    public function __construct()
    {
        $this->comment = new Comment();
        $this->post    = new Post();
        $this->user    = new User();
    }

    /**
     * Get comments for a post (JSON).
     */
    public function index(array $params = []): void
    {
        $postId = (int)($params['post_id'] ?? 0);
        if ($postId <= 0) {
            $this->json(['error' => 'Invalid post.'], 400);
            return;
        }

        $comments = $this->comment->findByPost($postId);

        // Escape comment content for safe rendering
        $comments = array_map(function ($c) {
            $c['content'] = htmlspecialchars($c['content'], ENT_QUOTES, 'UTF-8');
            $c['author']  = htmlspecialchars($c['author'], ENT_QUOTES, 'UTF-8');
            $c['time_ago'] = $this->timeAgo($c['created_at']);
            return $c;
        }, $comments);

        $this->json([
            'comments' => $comments,
            'count'    => count($comments),
        ]);
    }

    /**
     * Store a new comment (JSON).
     */
    public function store(array $params = []): void
    {
        if (!Session::isAuthenticated()) {
            $this->json(['error' => 'You must be logged in to comment.'], 401);
            return;
        }

        $postId  = (int)($params['post_id'] ?? 0);
        $content = $this->input('content');

        if ($postId <= 0) {
            $this->json(['error' => 'Invalid post.'], 400);
            return;
        }

        // Validate content
        $v = new Validator(['content' => $content]);
        $v->required('content', 'Comment')
          ->minLength('content', 1, 'Comment')
          ->maxLength('content', 1000, 'Comment');

        if ($v->fails()) {
            $this->json(['error' => $v->firstError()], 422);
            return;
        }

        // Check post exists
        $post = $this->post->findById($postId);
        if (!$post) {
            $this->json(['error' => 'Post not found.'], 404);
            return;
        }

        // Save comment
        $commentId = $this->comment->addComment($this->userId(), $postId, $content);

        // Send email notification to post author (if enabled)
        $this->notifyAuthor($post, $content);

        // Get the created comment with author info
        $currentUser = $this->user->findById($this->userId());

        $this->json([
            'success' => true,
            'comment' => [
                'id'         => $commentId,
                'content'    => htmlspecialchars($content, ENT_QUOTES, 'UTF-8'),
                'author'     => htmlspecialchars($currentUser['username'], ENT_QUOTES, 'UTF-8'),
                'time_ago'   => 'Just now',
                'created_at' => date('Y-m-d H:i:s'),
            ],
            'count' => $this->comment->countForPost($postId),
        ]);
    }

    /**
     * Notify the post author about a new comment via email.
     */
    private function notifyAuthor(array $post, string $commentContent): void
    {
        // Don't notify if the commenter is the author
        if ((int)$post['user_id'] === $this->userId()) {
            return;
        }

        $author = $this->user->findById((int)$post['user_id']);
        if (!$author || !$author['notify_comments']) {
            return;
        }

        $commenter = $this->user->findById($this->userId());
        $commenterName = $commenter ? $commenter['username'] : 'Someone';

        try {
            Mailer::sendCommentNotification(
                $author['email'],
                $author['username'],
                $commenterName,
                $commentContent,
                $post['id']
            );
        } catch (\Throwable $e) {
            // Log but don't fail the request
            error_log("Failed to send comment notification: " . $e->getMessage());
        }
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
