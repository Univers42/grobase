/**
 * Email Validator
 * Validates email addresses according to RFC 5322 specification
 */

export interface EmailValidationResult {
  isValid: boolean;
  email: string;
  errors: string[];
  normalized?: string;
  parts?: {
    local: string;
    domain: string;
    tld: string;
  };
}

export class EmailValidator {
  /**
   * RFC 5322 compliant email regex
   * Simplified but robust version that catches most real-world cases
   * Control characters are intentional per RFC 5322 specification
   */
  /* eslint-disable no-control-regex */
  private static readonly EMAIL_REGEX =
    /^(?:[a-z0-9!#$%&'*+/=?^_`{|}~-]+(?:\.[a-z0-9!#$%&'*+/=?^_`{|}~-]+)*|"(?:[\x01-\x08\x0b\x0c\x0e-\x1f\x21\x23-\x5b\x5d-\x7f]|\\[\x01-\x09\x0b\x0c\x0e-\x7f])*")@(?:(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z0-9](?:[a-z0-9-]*[a-z0-9])?|\[(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?|[a-z0-9-]*[a-z0-9]:(?:[\x01-\x08\x0b\x0c\x0e-\x1f\x21-\x5a\x53-\x7f]|\\[\x01-\x09\x0b\x0c\x0e-\x7f])+)\])$/i;
  /* eslint-enable no-control-regex */

  /**
   * Stricter practical regex for common use cases
   */
  private static readonly PRACTICAL_REGEX =
    /^[a-zA-Z0-9](?:[a-zA-Z0-9._+-]*[a-zA-Z0-9])?@[a-zA-Z0-9](?:[a-zA-Z0-9-]*[a-zA-Z0-9])?(?:\.[a-zA-Z]{2,})+$/;

  /**
   * Disposable email domains to reject
   */
  private static readonly DISPOSABLE_DOMAINS = new Set([
    'tempmail.com',
    'throwaway.email',
    'guerrillamail.com',
    'mailinator.com',
    '10minutemail.com',
    'yopmail.com',
    'trashmail.com',
    'fakeinbox.com',
    'sharklasers.com',
    'temp-mail.org',
  ]);

  /**
   * Validate an email address
   */
  static validate(
    email: string,
    options?: { strict?: boolean; rejectDisposable?: boolean },
  ): EmailValidationResult {
    const errors: string[] = [];
    const opts = { strict: true, rejectDisposable: false, ...options };

    // Basic checks
    if (!email || typeof email !== 'string') {
      return {
        isValid: false,
        email: email || '',
        errors: ['Email is required'],
      };
    }

    const trimmedEmail = email.trim().toLowerCase();

    // Length checks
    if (trimmedEmail.length < 3) {
      errors.push('Email is too short (minimum 3 characters)');
    }
    if (trimmedEmail.length > 254) {
      errors.push('Email is too long (maximum 254 characters)');
    }

    // Must contain exactly one @
    const atCount = (trimmedEmail.match(/@/g) || []).length;
    if (atCount === 0) {
      errors.push('Email must contain @ symbol');
    } else if (atCount > 1) {
      errors.push('Email must contain exactly one @ symbol');
    }

    // Split into local and domain parts
    const atIndex = trimmedEmail.lastIndexOf('@');
    if (atIndex === -1) {
      return { isValid: false, email: trimmedEmail, errors };
    }

    const local = trimmedEmail.substring(0, atIndex);
    const domain = trimmedEmail.substring(atIndex + 1);

    // Local part validation
    if (local.length === 0) {
      errors.push('Local part (before @) cannot be empty');
    }
    if (local.length > 64) {
      errors.push('Local part is too long (maximum 64 characters)');
    }
    if (local.startsWith('.')) {
      errors.push('Local part cannot start with a dot');
    }
    if (local.endsWith('.')) {
      errors.push('Local part cannot end with a dot');
    }
    if (local.includes('..')) {
      errors.push('Local part cannot contain consecutive dots');
    }

    // Domain part validation
    if (domain.length === 0) {
      errors.push('Domain part (after @) cannot be empty');
    }
    if (domain.length > 255) {
      errors.push('Domain part is too long (maximum 255 characters)');
    }
    if (domain.startsWith('.') || domain.startsWith('-')) {
      errors.push('Domain cannot start with a dot or hyphen');
    }
    if (domain.endsWith('.') || domain.endsWith('-')) {
      errors.push('Domain cannot end with a dot or hyphen');
    }
    if (domain.includes('..')) {
      errors.push('Domain cannot contain consecutive dots');
    }

    // Check TLD
    const domainParts = domain.split('.');
    const tld = domainParts[domainParts.length - 1];
    if (!tld || tld.length < 2) {
      errors.push(
        'Invalid top-level domain (TLD must be at least 2 characters)',
      );
    }
    if (tld && /^\d+$/.test(tld)) {
      errors.push('TLD cannot be purely numeric');
    }

    // Regex validation
    const regex = opts.strict ? this.PRACTICAL_REGEX : this.EMAIL_REGEX;
    if (errors.length === 0 && !regex.test(trimmedEmail)) {
      errors.push('Email format is invalid');
    }

    // Check for disposable domains
    if (opts.rejectDisposable && this.DISPOSABLE_DOMAINS.has(domain)) {
      errors.push('Disposable email addresses are not allowed');
    }

    return {
      isValid: errors.length === 0,
      email: trimmedEmail,
      normalized: trimmedEmail,
      errors,
      parts: errors.length === 0 ? { local, domain, tld } : undefined,
    };
  }

  /**
   * Quick validation (boolean only)
   */
  static isValid(email: string): boolean {
    return this.validate(email).isValid;
  }

  /**
   * Normalize an email address
   * - Lowercase
   * - Remove dots from gmail local parts
   * - Remove + tags
   */
  static normalize(email: string): string {
    const result = this.validate(email);
    if (!result.isValid || !result.parts) return email.trim().toLowerCase();

    let local = result.parts.local;
    const domain = result.parts.domain;

    // Gmail-specific normalization
    if (domain === 'gmail.com' || domain === 'googlemail.com') {
      // Remove dots (gmail ignores them)
      local = local.replace(/\./g, '');
      // Remove everything after +
      const plusIndex = local.indexOf('+');
      if (plusIndex !== -1) {
        local = local.substring(0, plusIndex);
      }
    }

    return `${local}@${domain}`;
  }

  /**
   * Suggest corrections for common typos
   */
  static suggestCorrection(email: string): string | null {
    const result = this.validate(email);
    if (result.isValid) return null;

    const corrections: Record<string, string> = {
      'gmial.com': 'gmail.com',
      'gmai.com': 'gmail.com',
      'gmail.co': 'gmail.com',
      'gmail.fr': 'gmail.com', // Keep as is, but could suggest
      'hotmal.com': 'hotmail.com',
      'hotmai.com': 'hotmail.com',
      'hotmail.fr': 'hotmail.fr',
      'yahooo.com': 'yahoo.com',
      'yaho.com': 'yahoo.com',
      'outloo.com': 'outlook.com',
      'outlok.com': 'outlook.com',
    };

    if (result.parts?.domain && corrections[result.parts.domain]) {
      return `${result.parts.local}@${corrections[result.parts.domain]}`;
    }

    return null;
  }
}
