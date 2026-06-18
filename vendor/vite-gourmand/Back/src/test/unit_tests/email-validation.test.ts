/**
 * Email Validation Test
 * Tests email format validation according to RFC 5322
 */

import { BaseTest, TestResult, FuzzyTestResult } from './base.test';
import { EmailValidator } from '../validators';
import { TestData, randomEmail, randomString } from '../utils/test-data';

export class EmailValidationTest extends BaseTest {
  name = 'email_validation';
  description = 'Validate email formats according to RFC 5322';
  category = 'validation';

  async run(): Promise<TestResult> {
    const { result, duration } = await this.measure(async () => {
      const errors: string[] = [];
      let passed = 0;
      let failed = 0;

      // Test valid emails
      for (const email of TestData.emails.valid) {
        const validation = EmailValidator.validate(email);
        if (validation.isValid) {
          passed++;
        } else {
          failed++;
          errors.push(
            `Expected valid: ${email} - Errors: ${validation.errors.join(', ')}`,
          );
        }
      }

      // Test invalid emails
      for (const emailData of TestData.emails.invalid) {
        const validation = EmailValidator.validate(emailData.email);
        if (!validation.isValid) {
          passed++;
        } else {
          failed++;
          errors.push(
            `Expected invalid: ${emailData.email} (${emailData.reason})`,
          );
        }
      }

      return { passed, failed, errors };
    });

    if (result.failed === 0) {
      return {
        ...this.success(`All ${result.passed} email validations passed`),
        duration,
        details: { passed: result.passed, failed: result.failed },
      };
    }

    return {
      ...this.failure(
        `${result.failed} email validations failed`,
        result.errors,
      ),
      duration,
      details: { passed: result.passed, failed: result.failed },
    };
  }

  async fuzzyRun(iterations: number = 100): Promise<FuzzyTestResult> {
    const results: TestResult[] = [];
    const failedCases: TestResult[] = [];

    for (let i = 0; i < iterations; i++) {
      const testType = Math.random() > 0.5 ? 'valid' : 'invalid';

      let email: string;
      let expectedValid: boolean;

      if (testType === 'valid') {
        // Generate valid random email
        email = randomEmail();
        expectedValid = true;
      } else {
        // Generate random invalid email
        const invalidType = Math.floor(Math.random() * 5);
        switch (invalidType) {
          case 0:
            email = randomString(10); // No @
            break;
          case 1:
            email = `@${randomString(5)}.com`; // No local part
            break;
          case 2:
            email = `${randomString(5)}@`; // No domain
            break;
          case 3:
            email = `${randomString(5)}@.com`; // Empty domain
            break;
          default:
            email = `${randomString(3)}@@${randomString(5)}.com`; // Double @
        }
        expectedValid = false;
      }

      const validation = EmailValidator.validate(email);
      const testPassed = validation.isValid === expectedValid;

      const testResult: TestResult = {
        name: `fuzzy_email_${i + 1}`,
        passed: testPassed,
        message: testPassed
          ? `Email '${email}' validated correctly`
          : `Email '${email}' expected ${expectedValid ? 'valid' : 'invalid'} but got ${validation.isValid ? 'valid' : 'invalid'}`,
        duration: 0,
        details: {
          email,
          expectedValid,
          actualValid: validation.isValid,
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
