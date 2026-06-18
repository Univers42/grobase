/**
 * Credit Card Validator
 * Validates credit card numbers using the Luhn algorithm (ISO/IEC 7812)
 */

export interface CreditCardValidationResult {
  isValid: boolean;
  cardNumber: string;
  errors: string[];
  cardType?: CreditCardType;
  normalized?: string;
  checkDigit?: number;
  issuer?: string;
}

export type CreditCardType =
  | 'Visa'
  | 'Mastercard'
  | 'AmEx'
  | 'Discover'
  | 'DinersClub'
  | 'JCB'
  | 'UnionPay'
  | 'Maestro'
  | 'Unknown';

/**
 * Card type configuration
 */
interface CardTypeConfig {
  name: CreditCardType;
  patterns: RegExp[];
  lengths: number[];
  cvvLength: number;
}

export class CreditCardValidator {
  /**
   * Card type configurations with IIN ranges (Issuer Identification Numbers)
   */
  private static readonly CARD_TYPES: CardTypeConfig[] = [
    {
      name: 'Visa',
      patterns: [/^4/],
      lengths: [13, 16, 19],
      cvvLength: 3,
    },
    {
      name: 'Mastercard',
      patterns: [/^5[1-5]/, /^2(2[2-9][1-9]|2[3-9]|[3-6]|7[0-1]|720)/],
      lengths: [16],
      cvvLength: 3,
    },
    {
      name: 'AmEx',
      patterns: [/^3[47]/],
      lengths: [15],
      cvvLength: 4,
    },
    {
      name: 'Discover',
      patterns: [
        /^6(?:011|5|4[4-9]|22(?:1(?:2[6-9]|[3-9])|[2-8]|9(?:[01]|2[0-5])))/,
      ],
      lengths: [16, 19],
      cvvLength: 3,
    },
    {
      name: 'DinersClub',
      patterns: [/^3(?:0[0-5]|[68])/],
      lengths: [14, 16, 19],
      cvvLength: 3,
    },
    {
      name: 'JCB',
      patterns: [/^(?:2131|1800|35\d{3})/],
      lengths: [15, 16, 19],
      cvvLength: 3,
    },
    {
      name: 'UnionPay',
      patterns: [/^(62|81)/],
      lengths: [16, 17, 18, 19],
      cvvLength: 3,
    },
    {
      name: 'Maestro',
      patterns: [/^(?:5[06789]|6)/],
      lengths: [12, 13, 14, 15, 16, 17, 18, 19],
      cvvLength: 3,
    },
  ];

  /**
   * Clean a card number (remove spaces, dashes)
   */
  private static cleanNumber(cardNumber: string): string {
    return cardNumber.replace(/[\s-]/g, '');
  }

  /**
   * Luhn Algorithm Implementation (ISO/IEC 7812)
   * Also known as "mod 10" algorithm
   *
   * Steps:
   * 1. From the rightmost digit (excluding check digit), double every second digit
   * 2. If doubling results in a number > 9, subtract 9
   * 3. Sum all the digits
   * 4. If total modulo 10 equals 0, the number is valid
   */
  static luhnCheck(cardNumber: string): boolean {
    const digits = cardNumber.replace(/\D/g, '');

    if (digits.length === 0) return false;

    let sum = 0;
    let isEven = false;

    // Process from right to left
    for (let i = digits.length - 1; i >= 0; i--) {
      let digit = Number.parseInt(digits[i], 10);

      if (isEven) {
        digit *= 2;
        if (digit > 9) {
          digit -= 9;
        }
      }

      sum += digit;
      isEven = !isEven;
    }

    return sum % 10 === 0;
  }

  /**
   * Calculate the Luhn check digit for a partial card number
   */
  static calculateCheckDigit(partialNumber: string): number {
    const digits = partialNumber.replace(/\D/g, '');
    let sum = 0;
    let isEven = true;

    // Process from right to left
    for (let i = digits.length - 1; i >= 0; i--) {
      let digit = Number.parseInt(digits[i], 10);

      if (isEven) {
        digit *= 2;
        if (digit > 9) {
          digit -= 9;
        }
      }

      sum += digit;
      isEven = !isEven;
    }

    return (10 - (sum % 10)) % 10;
  }

  /**
   * Detect the card type from the card number
   */
  static detectCardType(cardNumber: string): CreditCardType {
    const cleanedNumber = this.cleanNumber(cardNumber);

    for (const cardType of this.CARD_TYPES) {
      if (cardType.patterns.some((pattern) => pattern.test(cleanedNumber))) {
        return cardType.name;
      }
    }

    return 'Unknown';
  }

  /**
   * Get card type configuration
   */
  static getCardConfig(cardType: CreditCardType): CardTypeConfig | undefined {
    return this.CARD_TYPES.find((ct) => ct.name === cardType);
  }

  /**
   * Validate a credit card number
   */
  static validate(
    cardNumber: string,
    options?: { strict?: boolean },
  ): CreditCardValidationResult {
    const errors: string[] = [];
    const opts = { strict: true, ...options };

    // Basic checks
    if (!cardNumber || typeof cardNumber !== 'string') {
      return {
        isValid: false,
        cardNumber: cardNumber || '',
        errors: ['Card number is required'],
      };
    }

    const cleanedNumber = this.cleanNumber(cardNumber);

    // Check for non-numeric characters
    if (!/^\d+$/.test(cleanedNumber)) {
      errors.push('Card number must contain only digits');
    }

    // Length check (general range)
    if (cleanedNumber.length < 12) {
      errors.push('Card number is too short (minimum 12 digits)');
    }
    if (cleanedNumber.length > 19) {
      errors.push('Card number is too long (maximum 19 digits)');
    }

    // Check for all zeros or repeated digits
    if (/^0+$/.test(cleanedNumber)) {
      errors.push('Card number cannot be all zeros');
    }

    // Detect card type
    const cardType = this.detectCardType(cleanedNumber);
    const cardConfig = this.getCardConfig(cardType);

    // Validate length for specific card type
    if (cardConfig && opts.strict) {
      if (!cardConfig.lengths.includes(cleanedNumber.length)) {
        errors.push(
          `Invalid length for ${cardType}: expected ${cardConfig.lengths.join(' or ')} digits, got ${cleanedNumber.length}`,
        );
      }
    }

    // Luhn algorithm validation
    if (errors.length === 0 && !this.luhnCheck(cleanedNumber)) {
      errors.push('Invalid card number (Luhn check failed)');
    }

    // Calculate check digit for reference
    const checkDigit =
      cleanedNumber.length > 0
        ? Number.parseInt(cleanedNumber[cleanedNumber.length - 1], 10)
        : undefined;

    // Determine issuer
    let issuer: string | undefined;
    if (cardType !== 'Unknown') {
      const issuerMap: Record<CreditCardType, string> = {
        Visa: 'Visa Inc.',
        Mastercard: 'Mastercard Inc.',
        AmEx: 'American Express',
        Discover: 'Discover Financial Services',
        DinersClub: 'Diners Club International',
        JCB: 'JCB Co., Ltd.',
        UnionPay: 'China UnionPay',
        Maestro: 'Mastercard Inc.',
        Unknown: '',
      };
      issuer = issuerMap[cardType];
    }

    return {
      isValid: errors.length === 0,
      cardNumber: cleanedNumber,
      errors,
      cardType: errors.length === 0 ? cardType : undefined,
      normalized: errors.length === 0 ? cleanedNumber : undefined,
      checkDigit,
      issuer,
    };
  }

  /**
   * Quick validation (boolean only)
   */
  static isValid(cardNumber: string): boolean {
    return this.validate(cardNumber).isValid;
  }

  /**
   * Format a card number for display (masked)
   */
  static mask(cardNumber: string): string {
    const cleanedNumber = this.cleanNumber(cardNumber);
    if (cleanedNumber.length < 4) return cardNumber;

    // Show only last 4 digits
    const lastFour = cleanedNumber.slice(-4);
    const masked = '*'.repeat(cleanedNumber.length - 4);
    return `${masked}${lastFour}`;
  }

  /**
   * Format a card number for display with spaces
   */
  static format(cardNumber: string): string {
    const cleanedNumber = this.cleanNumber(cardNumber);
    const cardType = this.detectCardType(cleanedNumber);

    // AmEx uses 4-6-5 format
    if (cardType === 'AmEx') {
      return cleanedNumber.replace(/(\d{4})(\d{6})(\d{5})/, '$1 $2 $3');
    }

    // Most cards use 4-4-4-4 format
    return cleanedNumber.replace(/(\d{4})(?=\d)/g, '$1 ').trim();
  }

  /**
   * Generate a valid test card number for a given type
   */
  static generateTestCard(cardType: CreditCardType = 'Visa'): string {
    const prefixes: Record<CreditCardType, string> = {
      Visa: '4',
      Mastercard: '51',
      AmEx: '37',
      Discover: '6011',
      DinersClub: '38',
      JCB: '3528',
      UnionPay: '62',
      Maestro: '50',
      Unknown: '9',
    };

    const lengths: Record<CreditCardType, number> = {
      Visa: 16,
      Mastercard: 16,
      AmEx: 15,
      Discover: 16,
      DinersClub: 14,
      JCB: 16,
      UnionPay: 16,
      Maestro: 16,
      Unknown: 16,
    };

    const prefix = prefixes[cardType];
    const length = lengths[cardType];

    // Generate random middle digits
    let cardNumber = prefix;
    while (cardNumber.length < length - 1) {
      cardNumber += Math.floor(Math.random() * 10).toString();
    }

    // Calculate and append check digit
    const checkDigit = this.calculateCheckDigit(cardNumber);
    return cardNumber + checkDigit.toString();
  }
}
