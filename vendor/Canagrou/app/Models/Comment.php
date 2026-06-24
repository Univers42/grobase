<?php

declare(strict_types=1);

namespace App\Models;

use App\Core\Model;

/**
 * Comment Model
 */
class Comment extends Model
{
    protected string $table = 'comments';

    /**
     * Get all comments for a post with author info.
     */
    public function findByPost(int $postId): array
    {
        $stmt = $this->db->query(
            "SELECT c.*, u.username as author
             FROM {$this->table} c
             JOIN users u ON u.id = c.user_id
             WHERE c.post_id = :pid
             ORDER BY c.created_at ASC",
            ['pid' => $postId]
        );
        return $stmt->fetchAll();
    }

    /**
     * Create a new comment.
     */
    public function addComment(int $userId, int $postId, string $content): int
    {
        return $this->create([
            'user_id' => $userId,
            'post_id' => $postId,
            'content' => $content,
        ]);
    }

    /**
     * Count comments for a post.
     */
    public function countForPost(int $postId): int
    {
        $stmt = $this->db->query(
            "SELECT COUNT(*) as cnt FROM {$this->table} WHERE post_id = :pid",
            ['pid' => $postId]
        );
        return (int)$stmt->fetch()['cnt'];
    }

    /**
     * Delete a comment (only if owned by user).
     */
    public function deleteByUser(int $commentId, int $userId): bool
    {
        $comment = $this->findById($commentId);
        if (!$comment || (int)$comment['user_id'] !== $userId) {
            return false;
        }
        return $this->delete($commentId);
    }
}
