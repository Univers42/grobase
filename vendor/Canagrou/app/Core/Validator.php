<?php

declare(strict_types=1);

namespace App\Core;

/**
 * Input Validator
 * Provides chainable validation for form data.
 */
class Validator
{
    private array $errors = [];
    private array $data;

    public function __construct(array $data)
    {
        $this->data = $data;
    }

    /**
     * Validate that a field exists and is not empty.
     */
    public function required(string $field, string $label = ''): self
    {
        $label = $label ?: $field;
        if (!isset($this->data[$field]) || trim((string)$this->data[$field]) === '') {
            $this->errors[$field] = "{$label} is required.";
        }
        return $this;
    }

    /**
     * Validate email format.
     */
    public function email(string $field, string $label = ''): self
    {
        $label = $label ?: $field;
        $value = $this->data[$field] ?? '';
        if ($value !== '' && !filter_var($value, FILTER_VALIDATE_EMAIL)) {
            $this->errors[$field] = "{$label} must be a valid email address.";
        }
        return $this;
    }

    /**
     * Validate minimum length.
     */
    public function minLength(string $field, int $min, string $label = ''): self
    {
        $label = $label ?: $field;
        $value = $this->data[$field] ?? '';
        if ($value !== '' && mb_strlen($value) < $min) {
            $this->errors[$field] = "{$label} must be at least {$min} characters.";
        }
        return $this;
    }

    /**
     * Validate maximum length.
     */
    public function maxLength(string $field, int $max, string $label = ''): self
    {
        $label = $label ?: $field;
        $value = $this->data[$field] ?? '';
        if ($value !== '' && mb_strlen($value) > $max) {
            $this->errors[$field] = "{$label} must not exceed {$max} characters.";
        }
        return $this;
    }

    /**
     * Validate that a field matches another field (e.g., password confirmation).
     */
    public function matches(string $field, string $otherField, string $label = ''): self
    {
        $label = $label ?: $field;
        $value = $this->data[$field] ?? '';
        $other = $this->data[$otherField] ?? '';
        if ($value !== $other) {
            $this->errors[$field] = "{$label} does not match.";
        }
        return $this;
    }

    /**
     * Validate password complexity:
     * - At least 8 characters
     * - At least one uppercase letter
     * - At least one lowercase letter
     * - At least one digit
     * - At least one special character
     */
    public function passwordStrength(string $field, string $label = ''): self
    {
        $label = $label ?: $field;
        $value = $this->data[$field] ?? '';
        if ($value === '') {
            return $this;
        }

        if (mb_strlen($value) < 8) {
            $this->errors[$field] = "{$label} must be at least 8 characters.";
            return $this;
        }

        if (!preg_match('/[A-Z]/', $value)) {
            $this->errors[$field] = "{$label} must contain at least one uppercase letter.";
            return $this;
        }
        if (!preg_match('/[a-z]/', $value)) {
            $this->errors[$field] = "{$label} must contain at least one lowercase letter.";
            return $this;
        }
        if (!preg_match('/[0-9]/', $value)) {
            $this->errors[$field] = "{$label} must contain at least one digit.";
            return $this;
        }
        if (!preg_match('/[^A-Za-z0-9]/', $value)) {
            $this->errors[$field] = "{$label} must contain at least one special character.";
            return $this;
        }

        return $this;
    }

    /**
     * Validate alphanumeric + underscore only (for usernames).
     */
    public function alphanumeric(string $field, string $label = ''): self
    {
        $label = $label ?: $field;
        $value = $this->data[$field] ?? '';
        if ($value !== '' && !preg_match('/^[a-zA-Z0-9_]+$/', $value)) {
            $this->errors[$field] = "{$label} may only contain letters, numbers, and underscores.";
        }
        return $this;
    }

    /**
     * Check if validation passed.
     */
    public function passes(): bool
    {
        return empty($this->errors);
    }

    /**
     * Check if validation failed.
     */
    public function fails(): bool
    {
        return !$this->passes();
    }

    /**
     * Get all error messages.
     */
    public function errors(): array
    {
        return $this->errors;
    }

    /**
     * Get first error message.
     */
    public function firstError(): ?string
    {
        return empty($this->errors) ? null : reset($this->errors);
    }

    /**
     * Get sanitized value (trimmed + htmlspecialchars).
     */
    public static function sanitize(string $value): string
    {
        return htmlspecialchars(trim($value), ENT_QUOTES, 'UTF-8');
    }
}
