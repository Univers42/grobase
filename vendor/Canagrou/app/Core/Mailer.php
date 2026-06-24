<?php

declare(strict_types=1);

namespace App\Core;

/**
 * Email sender using PHP mail() through msmtp relay.
 * Sends HTML emails with a consistent template.
 */
class Mailer
{
    /**
     * Send an HTML email.
     */
    public static function send(string $to, string $subject, string $htmlBody): bool
    {
        $from = $_ENV['MAIL_FROM'] ?? 'noreply@camagru.local';
        $appUrl = $_ENV['APP_URL'] ?? 'http://localhost:8080';

        $html = self::wrapInTemplate($subject, $htmlBody, $appUrl);

        $headers = [
            'MIME-Version: 1.0',
            'Content-Type: text/html; charset=UTF-8',
            "From: Camagru <{$from}>",
            "Reply-To: {$from}",
            'X-Mailer: Camagru/1.0',
        ];

        return mail($to, $subject, $html, implode("\r\n", $headers));
    }

    /**
     * Wrap email body in a styled HTML template.
     */
    private static function wrapInTemplate(string $title, string $body, string $appUrl): string
    {
        $escapedTitle = htmlspecialchars($title, ENT_QUOTES, 'UTF-8');

        return <<<HTML
        <!DOCTYPE html>
        <html lang="en">
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <title>{$escapedTitle}</title>
        </head>
        <body style="margin:0; padding:0; background:#0f172a; font-family:'Segoe UI',Tahoma,Geneva,Verdana,sans-serif;">
            <div style="max-width:560px; margin:40px auto; background:#1e293b; border-radius:16px; overflow:hidden; border:1px solid #334155;">
                <div style="background:linear-gradient(135deg,#6366f1,#8b5cf6); padding:28px; text-align:center;">
                    <h1 style="color:#fff; margin:0; font-size:24px; letter-spacing:1px;">📸 Camagru</h1>
                </div>
                <div style="padding:32px; color:#e2e8f0; line-height:1.7; font-size:15px;">
                    {$body}
                </div>
                <div style="padding:20px 32px; background:#0f172a; text-align:center; color:#64748b; font-size:12px;">
                    <p style="margin:0;">Camagru — Photo editing made fun</p>
                    <p style="margin:4px 0 0 0;"><a href="{$appUrl}" style="color:#818cf8; text-decoration:none;">{$appUrl}</a></p>
                </div>
            </div>
        </body>
        </html>
        HTML;
    }

    /**
     * Send a verification email after registration.
     */
    public static function sendVerification(string $to, string $username, string $token): bool
    {
        $appUrl = $_ENV['APP_URL'] ?? 'http://localhost:8080';
        $link = "{$appUrl}/verify?token={$token}";
        $escapedUsername = htmlspecialchars($username, ENT_QUOTES, 'UTF-8');

        $body = <<<HTML
        <h2 style="color:#f1f5f9; margin-top:0;">Welcome, {$escapedUsername}! 🎉</h2>
        <p>Thanks for signing up for Camagru. Please verify your email to get started:</p>
        <div style="text-align:center; margin:28px 0;">
            <a href="{$link}" style="display:inline-block; background:linear-gradient(135deg,#6366f1,#8b5cf6); color:#fff; padding:14px 36px; border-radius:8px; text-decoration:none; font-weight:600; font-size:15px;">
                Verify My Email
            </a>
        </div>
        <p style="color:#94a3b8; font-size:13px;">If the button doesn't work, copy this link:<br>
        <a href="{$link}" style="color:#818cf8; word-break:break-all;">{$link}</a></p>
        HTML;

        return self::send($to, 'Verify your Camagru account', $body);
    }

    /**
     * Send a password reset email.
     */
    public static function sendPasswordReset(string $to, string $username, string $token): bool
    {
        $appUrl = $_ENV['APP_URL'] ?? 'http://localhost:8080';
        $link = "{$appUrl}/reset-password?token={$token}";
        $escapedUsername = htmlspecialchars($username, ENT_QUOTES, 'UTF-8');

        $body = <<<HTML
        <h2 style="color:#f1f5f9; margin-top:0;">Password Reset</h2>
        <p>Hi {$escapedUsername}, we received a request to reset your password:</p>
        <div style="text-align:center; margin:28px 0;">
            <a href="{$link}" style="display:inline-block; background:linear-gradient(135deg,#6366f1,#8b5cf6); color:#fff; padding:14px 36px; border-radius:8px; text-decoration:none; font-weight:600; font-size:15px;">
                Reset Password
            </a>
        </div>
        <p style="color:#94a3b8; font-size:13px;">This link expires in 1 hour. If you didn't request this, ignore this email.</p>
        HTML;

        return self::send($to, 'Reset your Camagru password', $body);
    }

    /**
     * Send a comment notification email.
     */
    public static function sendCommentNotification(string $to, string $authorName, string $commenterName, string $comment, int $postId): bool
    {
        $appUrl = $_ENV['APP_URL'] ?? 'http://localhost:8080';
        $link = "{$appUrl}/gallery#post-{$postId}";
        $escapedAuthor = htmlspecialchars($authorName, ENT_QUOTES, 'UTF-8');
        $escapedCommenter = htmlspecialchars($commenterName, ENT_QUOTES, 'UTF-8');
        $escapedComment = htmlspecialchars($comment, ENT_QUOTES, 'UTF-8');

        $body = <<<HTML
        <h2 style="color:#f1f5f9; margin-top:0;">New Comment 💬</h2>
        <p>Hi {$escapedAuthor}, <strong>{$escapedCommenter}</strong> commented on your photo:</p>
        <div style="background:#0f172a; border-left:4px solid #6366f1; padding:16px; margin:20px 0; border-radius:0 8px 8px 0;">
            <p style="margin:0; color:#cbd5e1; font-style:italic;">"{$escapedComment}"</p>
        </div>
        <div style="text-align:center; margin:24px 0;">
            <a href="{$link}" style="display:inline-block; background:linear-gradient(135deg,#6366f1,#8b5cf6); color:#fff; padding:12px 28px; border-radius:8px; text-decoration:none; font-weight:600; font-size:14px;">
                View in Gallery
            </a>
        </div>
        <p style="color:#64748b; font-size:12px;">You can disable notifications in your <a href="{$appUrl}/settings" style="color:#818cf8;">settings</a>.</p>
        HTML;

        return self::send($to, "New comment on your Camagru photo", $body);
    }
}
