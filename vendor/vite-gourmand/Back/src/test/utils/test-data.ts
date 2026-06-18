/**
 * Test Data Utilities
 * Provides random data generators and test fixtures for unit/fuzzy tests
 */

// ============================================================================
// Random Data Generators
// ============================================================================

/**
 * Generate a random string of specified length from given charset
 */
export function randomString(
  length: number,
  charset: string = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789',
): string {
  let result = '';
  for (let i = 0; i < length; i++) {
    result += charset.charAt(Math.floor(Math.random() * charset.length));
  }
  return result;
}

/**
 * Generate a random email address
 */
export function randomEmail(): string {
  const username = randomString(8, 'abcdefghijklmnopqrstuvwxyz');
  const domains = ['test.com', 'example.com', 'mail.test', 'demo.org'];
  const domain = domains[Math.floor(Math.random() * domains.length)];
  return `${username}@${domain}`;
}

/**
 * Generate a random password with configurable strength
 * @param strengthOrOptions - Either a strength string ('weak', 'medium', 'strong') or options object
 */
export function randomPassword(
  strengthOrOptions?:
    | 'weak'
    | 'medium'
    | 'strong'
    | {
        minLength?: number;
        maxLength?: number;
        includeSpecial?: boolean;
        includeNumbers?: boolean;
        includeUppercase?: boolean;
      },
): string {
  // Handle string-based strength parameter (backward compatibility)
  if (typeof strengthOrOptions === 'string') {
    switch (strengthOrOptions) {
      case 'weak':
        return randomString(6, 'abcdefghijklmnopqrstuvwxyz');
      case 'medium':
        return (
          randomString(
            8,
            'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ',
          ) + randomString(2, '0123456789')
        );
      case 'strong':
      default:
        return (
          randomString(1, 'ABCDEFGHIJKLMNOPQRSTUVWXYZ') +
          randomString(6, 'abcdefghijklmnopqrstuvwxyz') +
          randomString(3, '0123456789') +
          randomString(2, '!@#$%^&*')
        );
    }
  }

  const opts = {
    minLength: 12,
    maxLength: 20,
    includeSpecial: true,
    includeNumbers: true,
    includeUppercase: true,
    ...strengthOrOptions,
  };

  let charset = 'abcdefghijklmnopqrstuvwxyz';
  if (opts.includeUppercase) charset += 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';
  if (opts.includeNumbers) charset += '0123456789';
  if (opts.includeSpecial) charset += '!@#$%^&*()_+-=[]{}|;:,.<>?';

  const length =
    Math.floor(Math.random() * (opts.maxLength - opts.minLength + 1)) +
    opts.minLength;

  // Ensure at least one of each required character type
  let password = '';
  if (opts.includeUppercase)
    password += randomString(1, 'ABCDEFGHIJKLMNOPQRSTUVWXYZ');
  if (opts.includeNumbers) password += randomString(1, '0123456789');
  if (opts.includeSpecial) password += randomString(1, '!@#$%^&*()_+-=');
  password += randomString(1, 'abcdefghijklmnopqrstuvwxyz');

  // Fill remaining length
  const remaining = length - password.length;
  if (remaining > 0) {
    password += randomString(remaining, charset);
  }

  // Shuffle the password
  return password
    .split('')
    .sort(() => Math.random() - 0.5)
    .join('');
}

/**
 * Generate a random phone number
 */
export function randomPhone(
  format: 'FR' | 'US' | 'international' = 'FR',
): string {
  switch (format) {
    case 'FR': {
      // French mobile: 06 or 07 + 8 digits
      const prefix = Math.random() > 0.5 ? '06' : '07';
      return prefix + randomString(8, '0123456789');
    }
    case 'US':
      // US format: (XXX) XXX-XXXX
      return `(${randomString(3, '0123456789')}) ${randomString(3, '0123456789')}-${randomString(4, '0123456789')}`;
    case 'international':
      // International: +33 6 XX XX XX XX
      return `+33 6 ${randomString(2, '0123456789')} ${randomString(2, '0123456789')} ${randomString(2, '0123456789')} ${randomString(2, '0123456789')}`;
    default:
      return randomString(10, '0123456789');
  }
}

/**
 * Generate a valid credit card number using Luhn algorithm
 * @param typeOrPrefix - Either a card type ('visa', 'mastercard', 'amex') or a prefix string ('4', '51', '37', etc.)
 */
export function generateValidCreditCard(typeOrPrefix: string = 'visa'): string {
  let prefix: string;
  let length: number;

  // Handle both named types and raw prefixes
  switch (typeOrPrefix) {
    case 'visa':
    case '4':
      prefix = '4';
      length = 16;
      break;
    case 'mastercard':
    case '51':
    case '52':
    case '53':
    case '54':
    case '55':
      prefix =
        typeOrPrefix === 'mastercard'
          ? '5' + Math.floor(Math.random() * 5 + 1).toString()
          : typeOrPrefix;
      length = 16;
      break;
    case 'amex':
    case '34':
    case '37':
      prefix =
        typeOrPrefix === 'amex'
          ? Math.random() > 0.5
            ? '34'
            : '37'
          : typeOrPrefix;
      length = 15;
      break;
    case '6011': // Discover
      prefix = '6011';
      length = 16;
      break;
    default:
      // Use as raw prefix, default to 16 digits
      prefix = typeOrPrefix;
      length = 16;
  }

  // Generate random digits (excluding check digit)
  let cardNumber = prefix;
  while (cardNumber.length < length - 1) {
    cardNumber += Math.floor(Math.random() * 10).toString();
  }

  // Calculate Luhn check digit
  const checkDigit = calculateLuhnCheckDigit(cardNumber);
  return cardNumber + checkDigit;
}

/**
 * Calculate Luhn check digit
 */
function calculateLuhnCheckDigit(partial: string): string {
  let sum = 0;
  let isEven = true;

  for (let i = partial.length - 1; i >= 0; i--) {
    let digit = Number.parseInt(partial[i], 10);

    if (isEven) {
      digit *= 2;
      if (digit > 9) {
        digit -= 9;
      }
    }

    sum += digit;
    isEven = !isEven;
  }

  return ((10 - (sum % 10)) % 10).toString();
}

// ============================================================================
// Test Data Fixtures
// ============================================================================

export const TestData = {
  users: {
    valid: [
      {
        firstName: 'Jean',
        lastName: 'Dupont',
        email: 'jean.dupont@example.com',
        password: 'SecureP@ss123!',
        phone: '0612345678',
      },
      {
        firstName: 'Marie',
        lastName: 'Martin',
        email: 'marie.martin@test.com',
        password: 'MyStr0ng!Pass',
        phone: '0698765432',
      },
      {
        firstName: 'Pierre-André',
        lastName: "O'Brien",
        email: 'pierre.obrien@mail.fr',
        password: 'C0mpl3x#Pwd!',
        phone: '+33612345678',
      },
    ],
    invalid: [
      {
        firstName: '',
        lastName: 'Doe',
        email: 'test@example.com',
        password: 'password123',
        reason: 'Empty first name',
      },
      {
        firstName: 'J',
        lastName: 'Doe',
        email: 'test@example.com',
        password: 'password123',
        reason: 'First name too short',
      },
      {
        firstName: 'John',
        lastName: '',
        email: 'test@example.com',
        password: 'password123',
        reason: 'Empty last name',
      },
      {
        firstName: 'John',
        lastName: 'Doe',
        email: 'invalid-email',
        password: 'password123',
        reason: 'Invalid email format',
      },
      {
        firstName: 'John',
        lastName: 'Doe',
        email: 'test@example.com',
        password: '123',
        reason: 'Password too weak',
      },
    ],
  },

  passwords: {
    strong: [
      {
        password: 'MySecureP@ssw0rd!',
        reason: 'Mixed case, numbers, special chars, long',
      },
      { password: 'C0mpl3x#Passw0rd', reason: 'All character types, 16 chars' },
      { password: 'Tr0ub4dor&3horse', reason: 'XKCD style with complexity' },
      { password: '9K#mP2$vL8@nQ4!w', reason: 'High entropy random' },
      {
        password: 'CorrectHorseBattery1!',
        reason: 'Passphrase with complexity',
      },
    ],
    medium: [
      {
        password: 'Password123',
        reason: 'Common pattern but meets basic requirements',
      },
      {
        password: 'Test1234',
        reason: 'Meets length, has uppercase and number',
      },
      { password: 'Hello123', reason: 'Short but has mixed case and number' },
      { password: 'Welcome2024', reason: 'Dictionary word with number' },
    ],
    weak: [
      { password: '123456', reason: 'Only numbers, too short' },
      { password: 'password', reason: 'Common word, no complexity' },
      { password: 'abc', reason: 'Way too short' },
      { password: 'qwerty', reason: 'Keyboard pattern' },
      { password: 'admin', reason: 'Common word' },
      { password: '11111111', reason: 'Repeated characters' },
    ],
    blacklist: [
      'password',
      '123456',
      '12345678',
      'qwerty',
      'abc123',
      'monkey',
      'letmein',
      'dragon',
      'master',
      'login',
      'admin',
      'welcome',
      'password1',
      'Password1',
      'iloveyou',
      'sunshine',
      'princess',
      'football',
      'baseball',
      'superman',
    ],
  },

  emails: {
    valid: [
      'test@example.com',
      'user.name@domain.org',
      'user+tag@example.com',
      'firstname.lastname@company.co.uk',
      'email@subdomain.domain.com',
      'email@domain123.com',
      '1234567890@example.com',
      'user_name@example.com',
      'email@example.name',
      'email@example.museum',
    ],
    invalid: [
      { email: '', reason: 'Empty string' },
      { email: 'plainaddress', reason: 'Missing @ symbol' },
      { email: '@example.com', reason: 'Missing local part' },
      { email: 'email@', reason: 'Missing domain' },
      { email: 'email@.com', reason: 'Domain starts with dot' },
      { email: 'email@example..com', reason: 'Consecutive dots in domain' },
      { email: 'email @example.com', reason: 'Space in local part' },
      { email: 'email@exam ple.com', reason: 'Space in domain' },
      { email: 'email@-example.com', reason: 'Domain starts with hyphen' },
      { email: '.email@example.com', reason: 'Local part starts with dot' },
    ],
  },

  phones: {
    valid: {
      FR: [
        '0612345678',
        '0712345678',
        '06 12 34 56 78',
        '+33612345678',
        '+33 6 12 34 56 78',
        '0033612345678',
      ],
      US: [
        '(555) 123-4567',
        '555-123-4567',
        '5551234567',
        '+1 555 123 4567',
        '1-555-123-4567',
      ],
    },
    invalid: [
      { phone: '', reason: 'Empty string' },
      { phone: '123', reason: 'Too short' },
      { phone: 'abcdefghij', reason: 'Letters only' },
      { phone: '0812345678', reason: 'Invalid French prefix' },
      { phone: '+99123456789', reason: 'Invalid country code' },
    ],
  },

  creditCards: {
    valid: [
      { number: '4111111111111111', type: 'visa', name: 'Test Visa' },
      { number: '4012888888881881', type: 'visa', name: 'Test Visa 2' },
      {
        number: '5555555555554444',
        type: 'mastercard',
        name: 'Test Mastercard',
      },
      {
        number: '5105105105105100',
        type: 'mastercard',
        name: 'Test Mastercard 2',
      },
      { number: '378282246310005', type: 'amex', name: 'Test Amex' },
      { number: '371449635398431', type: 'amex', name: 'Test Amex 2' },
    ],
    invalid: [
      { number: '', reason: 'Empty string' },
      { number: '1234567890123456', reason: 'Invalid Luhn checksum' },
      { number: '4111111111111112', reason: 'Wrong check digit' },
      { number: '411111111111111', reason: 'Too short for Visa' },
      { number: '41111111111111111', reason: 'Too long for Visa' },
      { number: 'abcdefghijklmnop', reason: 'Non-numeric' },
      { number: '0000000000000000', reason: 'All zeros' },
    ],
  },

  addresses: {
    valid: [
      {
        street: '123 Main Street',
        city: 'Paris',
        postalCode: '75001',
        country: 'France',
      },
      {
        street: '456 Rue de la Paix',
        city: 'Lyon',
        postalCode: '69001',
        country: 'France',
      },
      {
        street: '789 Avenue des Champs-Élysées',
        city: 'Paris',
        postalCode: '75008',
        country: 'France',
      },
    ],
    invalid: [
      { street: '', reason: 'Empty street' },
      { postalCode: '1234', reason: 'Invalid postal code format' },
      { postalCode: 'ABCDE', reason: 'Non-numeric postal code' },
    ],
  },

  // SQL Injection test strings
  sqlInjection: [
    "' OR '1'='1",
    "'; DROP TABLE users; --",
    "' UNION SELECT * FROM users --",
    "1' OR '1' = '1",
    "admin'--",
    "' OR 1=1--",
    "'; EXEC xp_cmdshell('dir'); --",
    '1; UPDATE users SET admin=1 WHERE id=1',
  ],

  // XSS test strings
  xss: [
    '<script>alert("XSS")</script>',
    '<img src="x" onerror="alert(\'XSS\')">',
    '<svg onload="alert(\'XSS\')">',
    'javascript:alert("XSS")',
    '<iframe src="javascript:alert(\'XSS\')">',
    '"><script>alert("XSS")</script>',
    "'-alert('XSS')-'",
    '<body onload="alert(\'XSS\')">',
  ],

  // Unicode edge cases
  unicode: [
    '🔥🚀💻', // Emojis
    '日本語テスト', // Japanese
    'العربية', // Arabic (RTL)
    'עברית', // Hebrew (RTL)
    'Ñoño', // Spanish special chars
    'Привет', // Russian
    '中文测试', // Chinese
    'ＡＢＣＤ', // Full-width characters
    '\u200B', // Zero-width space
    '\u0000', // Null character
    'Test\nNewline', // Newline
    'Test\tTab', // Tab
  ],
};

export default TestData;
