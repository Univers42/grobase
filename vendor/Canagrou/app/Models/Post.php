<?php

declare(strict_types=1);

namespace App\Models;

use App\Core\Model;

/**
 * Post Model — Represents a captured/edited image.
 */
class Post extends Model
{
    protected string $table = 'posts';

    /**
     * Find all posts by a specific user (newest first).
     */
    public function findByUser(int $userId): array
    {
        $stmt = $this->db->query(
            "SELECT * FROM {$this->table} WHERE user_id = :uid ORDER BY created_at DESC",
            ['uid' => $userId]
        );
        return $stmt->fetchAll();
    }

    /**
     * Find all posts with author info + like/comment counts (for gallery).
     */
    public function findAllWithMeta(int $page = 1, int $perPage = 5, ?int $currentUserId = null): array
    {
        $offset = ($page - 1) * $perPage;

        // Total count
        $countStmt = $this->db->query("SELECT COUNT(*) as total FROM {$this->table}");
        $total = (int)$countStmt->fetch()['total'];

        // Posts with joined metadata
        $likedSubquery = $currentUserId
            ? ", (SELECT COUNT(*) FROM likes WHERE likes.post_id = p.id AND likes.user_id = :current_uid) as user_liked"
            : ", 0 as user_liked";

        $params = ['limit' => $perPage, 'offset' => $offset];
        if ($currentUserId) {
            $params['current_uid'] = $currentUserId;
        }

        $stmt = $this->db->query(
            "SELECT p.*,
                    u.username as author,
                    (SELECT COUNT(*) FROM likes WHERE likes.post_id = p.id) as like_count,
                    (SELECT COUNT(*) FROM comments WHERE comments.post_id = p.id) as comment_count
                    {$likedSubquery}
             FROM {$this->table} p
             JOIN users u ON u.id = p.user_id
             ORDER BY p.created_at DESC
             LIMIT :limit OFFSET :offset",
            $params
        );

        return [
            'data'       => $stmt->fetchAll(),
            'total'      => $total,
            'page'       => $page,
            'perPage'    => $perPage,
            'totalPages' => $total > 0 ? (int)ceil($total / $perPage) : 1,
        ];
    }

    /**
     * Find a single post with full metadata.
     */
    public function findWithMeta(int $id, ?int $currentUserId = null): ?array
    {
        $likedSubquery = $currentUserId
            ? ", (SELECT COUNT(*) FROM likes WHERE likes.post_id = p.id AND likes.user_id = :current_uid) as user_liked"
            : ", 0 as user_liked";

        $params = ['id' => $id];
        if ($currentUserId) {
            $params['current_uid'] = $currentUserId;
        }

        $stmt = $this->db->query(
            "SELECT p.*,
                    u.username as author,
                    (SELECT COUNT(*) FROM likes WHERE likes.post_id = p.id) as like_count,
                    (SELECT COUNT(*) FROM comments WHERE comments.post_id = p.id) as comment_count
                    {$likedSubquery}
             FROM {$this->table} p
             JOIN users u ON u.id = p.user_id
             WHERE p.id = :id
             LIMIT 1",
            $params
        );

        $result = $stmt->fetch();
        return $result ?: null;
    }

    /**
     * Create a new post (image capture).
     */
    public function createPost(int $userId, string $imagePath): int
    {
        return $this->create([
            'user_id'    => $userId,
            'image_path' => $imagePath,
        ]);
    }

    /**
     * Delete a post (only if owned by user).
     * Also removes the image file from disk.
     */
    public function deleteByUser(int $postId, int $userId): bool
    {
        $post = $this->findById($postId);
        if (!$post || (int)$post['user_id'] !== $userId) {
            return false;
        }

        // Remove image file
        $filePath = dirname(__DIR__, 2) . '/public' . $post['image_path'];
        if (file_exists($filePath)) {
            unlink($filePath);
        }

        return $this->delete($postId);
    }

    /**
     * Count posts by user (for stats).
     */
    public function countByUser(int $userId): int
    {
        $stmt = $this->db->query(
            "SELECT COUNT(*) as cnt FROM {$this->table} WHERE user_id = :uid",
            ['uid' => $userId]
        );
        return (int)$stmt->fetch()['cnt'];
    }
}
