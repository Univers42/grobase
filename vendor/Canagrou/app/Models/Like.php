<?php

declare(strict_types=1);

namespace App\Models;

use App\Core\Model;

/**
 * Like Model
 */
class Like extends Model
{
    protected string $table = 'likes';

    /**
     * Toggle like: if liked → unlike, if not → like.
     * Returns ['liked' => bool, 'count' => int].
     */
    public function toggle(int $userId, int $postId): array
    {
        $existing = $this->findByUserAndPost($userId, $postId);

        if ($existing) {
            $this->delete((int)$existing['id']);
        } else {
            $this->create([
                'user_id' => $userId,
                'post_id' => $postId,
            ]);
        }

        return [
            'liked' => !$existing,
            'count' => $this->countForPost($postId),
        ];
    }

    /**
     * Check if a user liked a post.
     */
    public function findByUserAndPost(int $userId, int $postId): ?array
    {
        $stmt = $this->db->query(
            "SELECT * FROM {$this->table} WHERE user_id = :uid AND post_id = :pid LIMIT 1",
            ['uid' => $userId, 'pid' => $postId]
        );
        $result = $stmt->fetch();
        return $result ?: null;
    }

    /**
     * Count total likes for a post.
     */
    public function countForPost(int $postId): int
    {
        $stmt = $this->db->query(
            "SELECT COUNT(*) as cnt FROM {$this->table} WHERE post_id = :pid",
            ['pid' => $postId]
        );
        return (int)$stmt->fetch()['cnt'];
    }
}
