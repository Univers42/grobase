/**
 * Password Strength Validator
 * Comprehensive password validation with entropy calculation
 */

export interface PasswordValidationResult {
  isValid: boolean;
  password: string;
  score: number; // 0-5
  strength: PasswordStrength;
  errors: string[];
  suggestions: string[];
  criteria: PasswordCriteria;
  entropy: number; // bits
  crackTime: CrackTimeEstimate;
}

export type PasswordStrength =
  | 'very_weak'
  | 'weak'
  | 'fair'
  | 'strong'
  | 'very_strong';

export interface PasswordCriteria {
  minLength: boolean;
  hasLowercase: boolean;
  hasUppercase: boolean;
  hasNumbers: boolean;
  hasSpecialChars: boolean;
  noCommonPatterns: boolean;
  noRepeatingChars: boolean;
  notInBlacklist: boolean;
}

export interface CrackTimeEstimate {
  online: string; // 10 attempts/sec
  offlineSlow: string; // 10k attempts/sec
  offlineFast: string; // 10B attempts/sec
}

export class PasswordValidator {
  /**
   * Common passwords blacklist (top 100)
   */
  private static readonly BLACKLIST = new Set([
    'password',
    '123456',
    '12345678',
    'qwerty',
    'abc123',
    'monkey',
    'master',
    'dragon',
    'letmein',
    'baseball',
    'iloveyou',
    'trustno1',
    'sunshine',
    'princess',
    'admin',
    'welcome',
    'shadow',
    'superman',
    'michael',
    'football',
    '123456789',
    '12345',
    '1234567',
    'password1',
    '1234567890',
    'qwerty123',
    'qwertyuiop',
    '111111',
    '123123',
    '000000',
    'password123',
    'admin123',
    'root',
    'toor',
    'pass',
    'test',
    'guest',
    'master123',
    'changeme',
    'passw0rd',
    'p@ssw0rd',
    'p@ssword',
    'login',
    'access',
    'hello',
    'charlie',
    'donald',
    'loveme',
    'hockey',
    'ranger',
    'thomas',
    'killer',
    'george',
    'computer',
    'michelle',
    'jennifer',
    'amanda',
    'ashley',
    'nicole',
    'jessica',
    'hunter',
    'pepper',
    'joshua',
    'zxcvbn',
    'asdfgh',
    'qazwsx',
    'password!',
    '1q2w3e4r',
    '1qaz2wsx',
    'qweasd',
    'aaaaaa',
    'secret',
    'solo',
    'matrix',
  ]);

  /**
   * Keyboard patterns to detect
   */
  private static readonly KEYBOARD_PATTERNS = [
    'qwerty',
    'qwertz',
    'azerty',
    'asdf',
    'zxcv',
    'qwer',
    'wasd',
    '1234',
    '2345',
    '3456',
    '4567',
    '5678',
    '6789',
    '7890',
    '0987',
    '9876',
    '8765',
    '7654',
    '6543',
    '5432',
    '4321',
    'abcd',
    'bcde',
    'cdef',
    'defg',
    'efgh',
    'fghi',
    'ghij',
    'hijk',
    'ijkl',
    'jklm',
  ];

  /**
   * Configuration
   */
  private static readonly CONFIG = {
    minLength: 8,
    maxLength: 128,
    minScore: 3, // Minimum acceptable score
    minEntropy: 28, // Minimum bits of entropy
  };

  /**
   * Character set sizes for entropy calculation
   */
  private static readonly CHARSET_SIZES = {
    lowercase: 26,
    uppercase: 26,
    numbers: 10,
    special: 32,
  };

  /**
   * Calculate password entropy in bits
   */
  private static calculateEntropy(password: string): number {
    let charsetSize = 0;

    if (/[a-z]/.test(password)) charsetSize += this.CHARSET_SIZES.lowercase;
    if (/[A-Z]/.test(password)) charsetSize += this.CHARSET_SIZES.uppercase;
    if (/[0-9]/.test(password)) charsetSize += this.CHARSET_SIZES.numbers;
    if (/[^a-zA-Z0-9]/.test(password))
      charsetSize += this.CHARSET_SIZES.special;

    if (charsetSize === 0) return 0;

    // Entropy = log2(charsetSize^length) = length * log2(charsetSize)
    return password.length * Math.log2(charsetSize);
  }

  /**
   * Estimate crack time based on entropy
   */
  private static estimateCrackTime(entropy: number): CrackTimeEstimate {
    // Number of possible combinations = 2^entropy
    const combinations = Math.pow(2, entropy);

    // Average attempts = combinations / 2
    const avgAttempts = combinations / 2;

    const formatTime = (seconds: number): string => {
      if (seconds < 1) return 'instantly';
      if (seconds < 60) return `${Math.round(seconds)} seconds`;
      if (seconds < 3600) return `${Math.round(seconds / 60)} minutes`;
      if (seconds < 86400) return `${Math.round(seconds / 3600)} hours`;
      if (seconds < 2592000) return `${Math.round(seconds / 86400)} days`;
      if (seconds < 31536000) return `${Math.round(seconds / 2592000)} months`;
      if (seconds < 3153600000)
        return `${Math.round(seconds / 31536000)} years`;
      if (seconds < 3.154e12)
        return `${Math.round(seconds / 31536000 / 1000)} thousand years`;
      if (seconds < 3.154e15)
        return `${Math.round(seconds / 31536000 / 1e6)} million years`;
      return 'centuries';
    };

    return {
      online: formatTime(avgAttempts / 10), // 10 attempts/sec (rate limited)
      offlineSlow: formatTime(avgAttempts / 1e4), // 10k attempts/sec
      offlineFast: formatTime(avgAttempts / 1e10), // 10B attempts/sec (modern GPU)
    };
  }

  /**
   * Check for common patterns
   */
  private static hasCommonPatterns(password: string): boolean {
    const lower = password.toLowerCase();

    // Check keyboard patterns
    for (const pattern of this.KEYBOARD_PATTERNS) {
      if (lower.includes(pattern)) return true;
    }

    // Check for repeated patterns (e.g., abcabc)
    for (let len = 2; len <= password.length / 2; len++) {
      const pattern = password.substring(0, len);
      // Escape special regex characters
      const escapedPattern = pattern.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
      try {
        const regex = new RegExp(`^(${escapedPattern})+$`, 'i');
        if (regex.test(password)) return true;
      } catch {
        // Invalid regex pattern, skip
        continue;
      }
    }

    // Check for dates (YYYY, MMDD, DDMM patterns)
    if (/(?:19|20)\d{2}/.test(password)) return true;

    return false;
  }

  /**
   * Check for repeating characters
   */
  private static hasRepeatingChars(password: string): boolean {
    // 3+ same characters in a row
    return /(.)\1{2,}/.test(password);
  }

  /**
   * Calculate password score (0-5)
   */
  private static calculateScore(
    criteria: PasswordCriteria,
    entropy: number,
  ): number {
    let score = 0;

    // Each criterion adds to score
    if (criteria.minLength) score++;
    if (criteria.hasLowercase && criteria.hasUppercase) score++;
    if (criteria.hasNumbers) score += 0.5;
    if (criteria.hasSpecialChars) score++;
    if (criteria.noCommonPatterns) score += 0.5;
    if (criteria.notInBlacklist) score++;

    // Bonus for high entropy
    if (entropy > 60) score += 0.5;
    if (entropy > 80) score += 0.5;

    // Penalty for repeating chars
    if (!criteria.noRepeatingChars) score -= 0.5;

    return Math.min(5, Math.max(0, Math.round(score)));
  }

  /**
   * Get strength label from score
   */
  private static getStrength(score: number): PasswordStrength {
    if (score <= 1) return 'very_weak';
    if (score === 2) return 'weak';
    if (score === 3) return 'fair';
    if (score === 4) return 'strong';
    return 'very_strong';
  }

  /**
   * Generate improvement suggestions
   */
  private static getSuggestions(
    criteria: PasswordCriteria,
    password: string,
  ): string[] {
    const suggestions: string[] = [];

    if (!criteria.minLength) {
      suggestions.push(`Use at least ${this.CONFIG.minLength} characters`);
    }
    if (!criteria.hasLowercase) {
      suggestions.push('Add lowercase letters (a-z)');
    }
    if (!criteria.hasUppercase) {
      suggestions.push('Add uppercase letters (A-Z)');
    }
    if (!criteria.hasNumbers) {
      suggestions.push('Add numbers (0-9)');
    }
    if (!criteria.hasSpecialChars) {
      suggestions.push('Add special characters (!@#$%^&*)');
    }
    if (!criteria.noCommonPatterns) {
      suggestions.push('Avoid common patterns like keyboard sequences');
    }
    if (!criteria.noRepeatingChars) {
      suggestions.push('Avoid repeating characters (aaa, 111)');
    }
    if (!criteria.notInBlacklist) {
      suggestions.push('Choose a less common password');
    }
    if (password.length < 12) {
      suggestions.push('Consider using a longer passphrase');
    }

    return suggestions;
  }

  /**
   * Validate a password
   */
  static validate(
    password: string,
    options?: { minLength?: number; minScore?: number },
  ): PasswordValidationResult {
    const errors: string[] = [];
    const opts = {
      minLength: this.CONFIG.minLength,
      minScore: this.CONFIG.minScore,
      ...options,
    };

    // Basic checks
    if (!password || typeof password !== 'string') {
      return {
        isValid: false,
        password: '',
        score: 0,
        strength: 'very_weak',
        errors: ['Password is required'],
        suggestions: ['Enter a password'],
        criteria: {
          minLength: false,
          hasLowercase: false,
          hasUppercase: false,
          hasNumbers: false,
          hasSpecialChars: false,
          noCommonPatterns: false,
          noRepeatingChars: false,
          notInBlacklist: false,
        },
        entropy: 0,
        crackTime: {
          online: 'instantly',
          offlineSlow: 'instantly',
          offlineFast: 'instantly',
        },
      };
    }

    // Evaluate criteria
    const criteria: PasswordCriteria = {
      minLength: password.length >= opts.minLength,
      hasLowercase: /[a-z]/.test(password),
      hasUppercase: /[A-Z]/.test(password),
      hasNumbers: /[0-9]/.test(password),
      hasSpecialChars: /[^a-zA-Z0-9]/.test(password),
      noCommonPatterns: !this.hasCommonPatterns(password),
      noRepeatingChars: !this.hasRepeatingChars(password),
      notInBlacklist: !this.BLACKLIST.has(password.toLowerCase()),
    };

    // Build errors
    if (!criteria.minLength) {
      errors.push(`Password must be at least ${opts.minLength} characters`);
    }
    if (password.length > this.CONFIG.maxLength) {
      errors.push(
        `Password must be less than ${this.CONFIG.maxLength} characters`,
      );
    }
    if (!criteria.hasLowercase) {
      errors.push('Password must contain lowercase letters');
    }
    if (!criteria.hasUppercase) {
      errors.push('Password must contain uppercase letters');
    }
    if (!criteria.hasNumbers) {
      errors.push('Password must contain numbers');
    }
    if (!criteria.hasSpecialChars) {
      errors.push('Password must contain special characters');
    }
    if (!criteria.notInBlacklist) {
      errors.push('Password is too common');
    }

    // Calculate metrics
    const entropy = this.calculateEntropy(password);
    const score = this.calculateScore(criteria, entropy);
    const strength = this.getStrength(score);
    const crackTime = this.estimateCrackTime(entropy);
    const suggestions = this.getSuggestions(criteria, password);

    // Determine validity
    const isValid =
      score >= opts.minScore && criteria.notInBlacklist && criteria.minLength;

    return {
      isValid,
      password: '*'.repeat(password.length), // Don't expose the password
      score,
      strength,
      errors,
      suggestions,
      criteria,
      entropy: Math.round(entropy * 10) / 10,
      crackTime,
    };
  }

  /**
   * Quick validation (boolean only)
   */
  static isValid(password: string): boolean {
    return this.validate(password).isValid;
  }

  /**
   * Get password strength score only
   */
  static getScore(password: string): number {
    return this.validate(password).score;
  }

  /**
   * Generate a secure random password
   */
  static generate(length: number = 16): string {
    const lowercase = 'abcdefghijklmnopqrstuvwxyz';
    const uppercase = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';
    const numbers = '0123456789';
    const special = '!@#$%^&*()_+-=[]{}|;:,.<>?';
    const all = lowercase + uppercase + numbers + special;

    // Ensure at least one of each type
    let password = '';
    password += lowercase[Math.floor(Math.random() * lowercase.length)];
    password += uppercase[Math.floor(Math.random() * uppercase.length)];
    password += numbers[Math.floor(Math.random() * numbers.length)];
    password += special[Math.floor(Math.random() * special.length)];

    // Fill the rest randomly
    for (let i = password.length; i < length; i++) {
      password += all[Math.floor(Math.random() * all.length)];
    }

    // Shuffle the password
    return password
      .split('')
      .sort(() => Math.random() - 0.5)
      .join('');
  }
}
