/**
 * Credit Card Verification Test
 * Tests credit card validation using Luhn algorithm
 */

import { BaseTest, TestResult, FuzzyTestResult } from './base.test';
import { CreditCardValidator, CreditCardType } from '../validators';
import {
  TestData,
  generateValidCreditCard,
  randomString,
} from '../utils/test-data';

export class VerifyCreditCardTest extends BaseTest {
  name = 'verif_credit_card';
  description =
    'Validate credit card numbers using Luhn algorithm (ISO/IEC 7812)';
  category = 'validation';

  async run(): Promise<TestResult> {
    const { result, duration } = await this.measure(async () => {
      const errors: string[] = [];
      let passed = 0;
      let failed = 0;

      // Test valid credit cards
      for (const card of TestData.creditCards.valid) {
        const validation = CreditCardValidator.validate(card.number);
        if (validation.isValid) {
          passed++;
          // Also verify card type detection
          if (validation.cardType !== card.type) {
            errors.push(
              `Card ${card.number}: expected type ${card.type}, got ${validation.cardType}`,
            );
          }
        } else {
          failed++;
          errors.push(
            `Expected valid: ${card.number} (${card.type}) - Errors: ${validation.errors.join(', ')}`,
          );
        }
      }

      // Test invalid credit cards
      for (const card of TestData.creditCards.invalid) {
        const validation = CreditCardValidator.validate(card.number);
        if (!validation.isValid) {
          passed++;
        } else {
          failed++;
          errors.push(`Expected invalid: ${card.number} (${card.reason})`);
        }
      }

      // Test Luhn algorithm specifically
      const luhnTests = [
        { number: '79927398713', expected: true, desc: 'Wikipedia example' },
        { number: '79927398710', expected: false, desc: 'Wrong check digit' },
        { number: '4532015112830366', expected: true, desc: 'Visa test card' },
        {
          number: '4532015112830367',
          expected: false,
          desc: 'Visa wrong check',
        },
      ];

      for (const test of luhnTests) {
        const luhnValid = CreditCardValidator.luhnCheck(test.number);
        if (luhnValid === test.expected) {
          passed++;
        } else {
          failed++;
          errors.push(
            `Luhn test failed for ${test.number} (${test.desc}): expected ${test.expected}, got ${luhnValid}`,
          );
        }
      }

      // Test check digit calculation
      const checkDigitTests = [
        { partial: '7992739871', expected: 3 },
        { partial: '453201511283036', expected: 6 },
      ];

      for (const test of checkDigitTests) {
        const checkDigit = CreditCardValidator.calculateCheckDigit(
          test.partial,
        );
        if (checkDigit === test.expected) {
          passed++;
        } else {
          failed++;
          errors.push(
            `Check digit for ${test.partial}: expected ${test.expected}, got ${checkDigit}`,
          );
        }
      }

      return { passed, failed, errors };
    });

    if (result.failed === 0) {
      return {
        ...this.success(
          `All ${result.passed} credit card validations passed (Luhn algorithm verified)`,
        ),
        duration,
        details: { passed: result.passed, failed: result.failed },
      };
    }

    return {
      ...this.failure(
        `${result.failed} credit card validations failed`,
        result.errors,
      ),
      duration,
      details: { passed: result.passed, failed: result.failed },
    };
  }

  async fuzzyRun(iterations: number = 100): Promise<FuzzyTestResult> {
    const results: TestResult[] = [];
    const failedCases: TestResult[] = [];

    const cardTypes: CreditCardType[] = [
      'Visa',
      'Mastercard',
      'AmEx',
      'Discover',
    ];

    for (let i = 0; i < iterations; i++) {
      const testType = Math.random() > 0.3 ? 'valid' : 'invalid';

      let cardNumber: string;
      let expectedValid: boolean;

      if (testType === 'valid') {
        // Generate valid card using our generator
        const cardType =
          cardTypes[Math.floor(Math.random() * cardTypes.length)];
        const prefix =
          cardType === 'Visa'
            ? '4'
            : cardType === 'Mastercard'
              ? '51'
              : cardType === 'AmEx'
                ? '37'
                : '6011';
        cardNumber = generateValidCreditCard(prefix);
        expectedValid = true;
      } else {
        // Generate invalid card
        const invalidType = Math.floor(Math.random() * 4);
        switch (invalidType) {
          case 0: {
            // Invalid Luhn - change a digit
            cardNumber = generateValidCreditCard('4');
            const pos = Math.floor(Math.random() * (cardNumber.length - 1));
            const newDigit = (
              (Number.parseInt(cardNumber[pos]) + 1) %
              10
            ).toString();
            cardNumber =
              cardNumber.substring(0, pos) +
              newDigit +
              cardNumber.substring(pos + 1);
            break;
          }
          case 1:
            // Too short
            cardNumber = randomString(8, '0123456789');
            break;
          case 2:
            // Too long
            cardNumber = randomString(25, '0123456789');
            break;
          default:
            // Non-numeric
            cardNumber = randomString(16, 'abcdefghijklmnop');
        }
        expectedValid = false;
      }

      const validation = CreditCardValidator.validate(cardNumber);
      const testPassed = validation.isValid === expectedValid;

      const testResult: TestResult = {
        name: `fuzzy_credit_card_${i + 1}`,
        passed: testPassed,
        message: testPassed
          ? `Card '${CreditCardValidator.mask(cardNumber)}' validated correctly`
          : `Card '${CreditCardValidator.mask(cardNumber)}' expected ${expectedValid ? 'valid' : 'invalid'} but got ${validation.isValid ? 'valid' : 'invalid'}`,
        duration: 0,
        details: {
          cardNumber: CreditCardValidator.mask(cardNumber),
          expectedValid,
          actualValid: validation.isValid,
          cardType: validation.cardType,
          errors: validation.errors,
        },
      };

      results.push(testResult);
      if (!testPassed) {
        failedCases.push(testResult);
      }
    }

    return {
      iterations,
      passed: results.filter((r) => r.passed).length,
      failed: results.filter((r) => !r.passed).length,
      results,
      failedCases,
    };
  }
}
