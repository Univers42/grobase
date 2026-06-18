/**
 * Phone Number Validator
 * Validates phone numbers according to E.164 standard and regional formats
 */

export interface PhoneValidationResult {
  isValid: boolean;
  phone: string;
  errors: string[];
  normalized?: string;
  countryCode?: string;
  nationalNumber?: string;
  format?: 'E164' | 'NATIONAL' | 'LOCAL';
}

/**
 * Country phone configurations
 */
interface CountryPhoneConfig {
  code: string;
  name: string;
  pattern: RegExp;
  length: number[];
  mobilePatterns?: RegExp[];
}

export class PhoneValidator {
  /**
   * Country configurations for phone validation
   */
  private static readonly COUNTRIES: Record<string, CountryPhoneConfig> = {
    FR: {
      code: '+33',
      name: 'France',
      pattern: /^(?:\+33|0033|0)[1-9](?:[0-9]{8})$/,
      length: [9, 10], // Without/with leading 0
      mobilePatterns: [/^(?:\+33|0033|0)[67]\d{8}$/],
    },
    US: {
      code: '+1',
      name: 'United States',
      pattern: /^(?:\+1)?[2-9]\d{2}[2-9]\d{6}$/,
      length: [10],
    },
    UK: {
      code: '+44',
      name: 'United Kingdom',
      pattern: /^(?:\+44|0044|0)(?:7\d{9}|[1-6]\d{8,9}|[89]\d{8,9})$/,
      length: [10, 11],
    },
    DE: {
      code: '+49',
      name: 'Germany',
      pattern: /^(?:\+49|0049|0)[1-9]\d{6,13}$/,
      length: [7, 14],
    },
    ES: {
      code: '+34',
      name: 'Spain',
      pattern: /^(?:\+34)?[6-9]\d{8}$/,
      length: [9],
    },
    IT: {
      code: '+39',
      name: 'Italy',
      pattern: /^(?:\+39)?0?\d{6,11}$/,
      length: [6, 11],
    },
    BE: {
      code: '+32',
      name: 'Belgium',
      pattern: /^(?:\+32|0032|0)[1-9]\d{7,8}$/,
      length: [8, 9],
    },
    CH: {
      code: '+41',
      name: 'Switzerland',
      pattern: /^(?:\+41|0041|0)[1-9]\d{8}$/,
      length: [9],
    },
  };

  /**
   * Clean a phone number (remove spaces, dashes, parentheses)
   */
  private static cleanNumber(phone: string): string {
    return phone.replace(/[\s\-().]/g, '');
  }

  /**
   * Validate a phone number
   */
  static validate(
    phone: string,
    options?: { country?: string; strict?: boolean },
  ): PhoneValidationResult {
    const errors: string[] = [];
    const opts = { country: 'FR', strict: false, ...options };

    // Basic checks
    if (!phone || typeof phone !== 'string') {
      return {
        isValid: false,
        phone: phone || '',
        errors: ['Phone number is required'],
      };
    }

    const cleanedPhone = this.cleanNumber(phone);

    // Check for non-numeric characters (except leading +)
    const numericPart = cleanedPhone.startsWith('+')
      ? cleanedPhone.substring(1)
      : cleanedPhone;
    if (!/^\d+$/.test(numericPart)) {
      errors.push(
        'Phone number must contain only digits (and optional + prefix)',
      );
    }

    // Length checks
    if (cleanedPhone.length < 6) {
      errors.push('Phone number is too short (minimum 6 digits)');
    }
    if (cleanedPhone.length > 15) {
      errors.push('Phone number is too long (maximum 15 digits per E.164)');
    }

    // Check for all zeros or repeated digits
    if (/^0+$/.test(numericPart)) {
      errors.push('Phone number cannot be all zeros');
    }
    if (/^(\d)\1+$/.test(numericPart)) {
      errors.push('Phone number cannot be all repeated digits');
    }

    // Country-specific validation
    const countryConfig = this.COUNTRIES[opts.country.toUpperCase()];
    let normalized = cleanedPhone;
    let countryCode: string | undefined;
    let nationalNumber: string | undefined;
    let format: 'E164' | 'NATIONAL' | 'LOCAL' | undefined;

    if (countryConfig) {
      // Try to normalize to E.164
      if (cleanedPhone.startsWith('+')) {
        format = 'E164';
        countryCode = countryConfig.code;
        nationalNumber = cleanedPhone.substring(countryConfig.code.length);
      } else if (cleanedPhone.startsWith('00')) {
        format = 'E164';
        // International format with 00
        const codeWithoutPlus = countryConfig.code.substring(1);
        if (cleanedPhone.startsWith('00' + codeWithoutPlus)) {
          countryCode = countryConfig.code;
          nationalNumber = cleanedPhone.substring(2 + codeWithoutPlus.length);
        }
      } else if (cleanedPhone.startsWith('0')) {
        format = 'NATIONAL';
        countryCode = countryConfig.code;
        nationalNumber = cleanedPhone.substring(1);
        normalized = countryConfig.code + nationalNumber;
      } else {
        format = 'LOCAL';
        countryCode = countryConfig.code;
        nationalNumber = cleanedPhone;
        normalized = countryConfig.code + cleanedPhone;
      }

      // Validate against country pattern
      if (
        errors.length === 0 &&
        opts.strict &&
        !countryConfig.pattern.test(cleanedPhone)
      ) {
        errors.push(`Invalid phone number format for ${countryConfig.name}`);
      }
    } else {
      // Generic E.164 validation
      if (cleanedPhone.startsWith('+')) {
        format = 'E164';
        normalized = cleanedPhone;
      } else {
        format = 'LOCAL';
      }
    }

    return {
      isValid: errors.length === 0,
      phone: cleanedPhone,
      errors,
      normalized: errors.length === 0 ? normalized : undefined,
      countryCode,
      nationalNumber,
      format,
    };
  }

  /**
   * Quick validation (boolean only)
   */
  static isValid(phone: string, country?: string): boolean {
    return this.validate(phone, { country }).isValid;
  }

  /**
   * Normalize a phone number to E.164 format
   */
  static normalize(phone: string, country: string = 'FR'): string {
    const result = this.validate(phone, { country });
    return result.normalized || phone;
  }

  /**
   * Format a phone number for display
   */
  static formatForDisplay(phone: string, country: string = 'FR'): string {
    const result = this.validate(phone, { country });
    if (!result.isValid || !result.nationalNumber) return phone;

    // French formatting: 06 12 34 56 78
    if (country === 'FR' && result.nationalNumber.length === 9) {
      const num = '0' + result.nationalNumber;
      return num.replace(
        /(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})/,
        '$1 $2 $3 $4 $5',
      );
    }

    return phone;
  }

  /**
   * Check if a phone number is a mobile number
   */
  static isMobile(phone: string, country: string = 'FR'): boolean {
    const countryConfig = this.COUNTRIES[country.toUpperCase()];
    if (!countryConfig?.mobilePatterns) return false;

    const cleanedPhone = this.cleanNumber(phone);
    return countryConfig.mobilePatterns.some((pattern) =>
      pattern.test(cleanedPhone),
    );
  }

  /**
   * Detect the country from a phone number
   */
  static detectCountry(phone: string): string | null {
    const cleanedPhone = this.cleanNumber(phone);

    for (const [code, config] of Object.entries(this.COUNTRIES)) {
      if (
        cleanedPhone.startsWith(config.code) ||
        cleanedPhone.startsWith('00' + config.code.substring(1))
      ) {
        return code;
      }
    }

    // Default to FR if starts with 0
    if (cleanedPhone.startsWith('0') && cleanedPhone.length === 10) {
      return 'FR';
    }

    return null;
  }
}
