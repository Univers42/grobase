/**
 * Email validation
 */
export function isValidEmail(email: string): boolean {
  const regex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
  return regex.test(email);
}

/**
 * Password strength validation
 * Requires: 8+ chars, 1 uppercase, 1 lowercase, 1 digit, 1 special char
 */
export function isStrongPassword(password: string): boolean {
  if (password.length < 8) return false;
  if (!/[A-Z]/.test(password)) return false;
  if (!/[a-z]/.test(password)) return false;
  if (!/[0-9]/.test(password)) return false;
  if (!/[!@#$%^&*()_+\-=[\]{};':"\\|,.<>/?]/.test(password)) return false;
  return true;
}

/**
 * Get password strength feedback
 */
export function getPasswordStrength(password: string): {
  score: number;
  label: string;
  color: string;
  suggestions: string[];
} {
  const suggestions: string[] = [];
  let score = 0;

  if (password.length >= 8) score++;
  else suggestions.push('At least 8 characters');

  if (password.length >= 12) score++;

  if (/[A-Z]/.test(password)) score++;
  else suggestions.push('One uppercase letter');

  if (/[a-z]/.test(password)) score++;
  else suggestions.push('One lowercase letter');

  if (/[0-9]/.test(password)) score++;
  else suggestions.push('One digit');

  if (/[!@#$%^&*()_+\-=[\]{};':"\\|,.<>/?]/.test(password)) score++;
  else suggestions.push('One special character');

  const labels = ['Very weak', 'Weak', 'Fair', 'Good', 'Strong', 'Very strong'];
  const colors = ['#d32f2f', '#f44336', '#ff9800', '#ffc107', '#4caf50', '#2e7d32'];

  const index = Math.min(score, labels.length - 1);
  return {
    score,
    label: labels[index],
    color: colors[index],
    suggestions,
  };
}

/**
 * Username validation
 */
export function isValidUsername(username: string): boolean {
  if (username.length < 3 || username.length > 30) return false;
  return /^[a-zA-Z0-9_-]+$/.test(username);
}

/**
 * Validate required field
 */
export function isRequired(value: string | undefined | null): boolean {
  return value !== undefined && value !== null && value.trim().length > 0;
}

/**
 * Validate minimum length
 */
export function hasMinLength(value: string, min: number): boolean {
  return value.length >= min;
}

/**
 * Validate maximum length
 */
export function hasMaxLength(value: string, max: number): boolean {
  return value.length <= max;
}
