<?php

declare(strict_types=1);

namespace App\Models;

use App\Core\Model;

class User extends Model
{
    protected string $table = 'users';

    /**
     * Find a user by username.
     */
    public function findByUsername(string $username): ?array
    {
        $stmt = $this->db->query(
            "SELECT * FROM {$this->table} WHERE username = :username LIMIT 1",
            ['username' => $username]
        );
        $result = $stmt->fetch();
        return $result ?: null;
    }

    /**
     * Find a user by email.
     */
    public function findByEmail(string $email): ?array
    {
        $stmt = $this->db->query(
            "SELECT * FROM {$this->table} WHERE email = :email LIMIT 1",
            ['email' => $email]
        );
        $result = $stmt->fetch();
        return $result ?: null;
    }

    /**
     * Find a user by verification token.
     */
    public function findByVerificationToken(string $token): ?array
    {
        $stmt = $this->db->query(
            "SELECT * FROM {$this->table} WHERE verification_token = :token LIMIT 1",
            ['token' => $token]
        );
        $result = $stmt->fetch();
        return $result ?: null;
    }

    /**
     * Find a user by reset token (and check expiry).
     */
    public function findByResetToken(string $token): ?array
    {
        $stmt = $this->db->query(
            "SELECT * FROM {$this->table} WHERE reset_token = :token AND reset_expires > NOW() LIMIT 1",
            ['token' => $token]
        );
        $result = $stmt->fetch();
        return $result ?: null;
    }

    /**
     * Create a new user with hashed password.
     */
    public function register(string $username, string $email, string $password): int
    {
        $hash = password_hash($password, PASSWORD_BCRYPT);
        $token = bin2hex(random_bytes(32));

        return $this->create([
            'username'           => $username,
            'email'              => $email,
            'password'           => $hash,
            'verified'           => 0,
            'verification_token' => $token,
            'notify_comments'    => 1,
        ]);
    }

    /**
     * Mark a user as verified.
     */
    public function verify(int $id): bool
    {
        return $this->update($id, [
            'verified'           => 1,
            'verification_token' => null,
        ]);
    }

    /**
     * Set a password reset token.
     */
    public function setResetToken(int $id): string
    {
        $token = bin2hex(random_bytes(32));
        $expires = date('Y-m-d H:i:s', strtotime('+1 hour'));

        $this->update($id, [
            'reset_token'   => $token,
            'reset_expires' => $expires,
        ]);

        return $token;
    }

    /**
     * Update password and clear reset token.
     */
    public function updatePassword(int $id, string $newPassword): bool
    {
        $hash = password_hash($newPassword, PASSWORD_BCRYPT);
        return $this->update($id, [
            'password'      => $hash,
            'reset_token'   => null,
            'reset_expires' => null,
        ]);
    }

    /**
     * Update username.
     */
    public function updateUsername(int $id, string $username): bool
    {
        return $this->update($id, ['username' => $username]);
    }

    /**
     * Update email (requires re-verification).
     */
    public function updateEmail(int $id, string $email): array
    {
        $token = bin2hex(random_bytes(32));
        $this->update($id, [
            'email'              => $email,
            'verified'           => 0,
            'verification_token' => $token,
        ]);
        return ['token' => $token];
    }

    /**
     * Toggle email notification preference.
     */
    public function updateNotifyComments(int $id, bool $notify): bool
    {
        return $this->update($id, ['notify_comments' => $notify ? 1 : 0]);
    }
}
