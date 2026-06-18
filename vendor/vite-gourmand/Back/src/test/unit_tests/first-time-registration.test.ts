/**
 * First Time Registration Test
 * Simulates a complete first-time user registration flow
 */

import { BaseTest, TestResult, FuzzyTestResult } from './base.test';
import {
  EmailValidator,
  PasswordValidator,
  PhoneValidator,
} from '../validators';
import {
  TestData,
  randomEmail,
  randomPassword,
  randomPhone,
  randomString,
} from '../utils/test-data';

interface RegistrationData {
  firstName: string;
  lastName: string;
  email: string;
  password: string;
  phone?: string;
  acceptTerms: boolean;
}

interface RegistrationValidationResult {
  isValid: boolean;
  errors: Record<string, string[]>;
  data?: RegistrationData;
}

export class FirstTimeRegistrationTest extends BaseTest {
  name = 'first_time_registration';
  description =
    'Simulate first-time user registration with complete validation';
  category = 'flow';

  private validateRegistration(
    data: Partial<RegistrationData>,
  ): RegistrationValidationResult {
    const errors: Record<string, string[]> = {};

    // First name validation
    if (!data.firstName || data.firstName.trim().length === 0) {
      errors.firstName = ['First name is required'];
    } else if (data.firstName.length < 2) {
      errors.firstName = ['First name must be at least 2 characters'];
    } else if (data.firstName.length > 50) {
      errors.firstName = ['First name must be less than 50 characters'];
    } else if (!/^[a-zA-ZÀ-ÿ\s'-]+$/.test(data.firstName)) {
      errors.firstName = ['First name contains invalid characters'];
    }

    // Last name validation
    if (!data.lastName || data.lastName.trim().length === 0) {
      errors.lastName = ['Last name is required'];
    } else if (data.lastName.length < 2) {
      errors.lastName = ['Last name must be at least 2 characters'];
    } else if (data.lastName.length > 50) {
      errors.lastName = ['Last name must be less than 50 characters'];
    } else if (!/^[a-zA-ZÀ-ÿ\s'-]+$/.test(data.lastName)) {
      errors.lastName = ['Last name contains invalid characters'];
    }

    // Email validation
    if (!data.email) {
      errors.email = ['Email is required'];
    } else {
      const emailResult = EmailValidator.validate(data.email);
      if (!emailResult.isValid) {
        errors.email = emailResult.errors;
      }
    }

    // Password validation
    if (!data.password) {
      errors.password = ['Password is required'];
    } else {
      const passwordResult = PasswordValidator.validate(data.password);
      if (!passwordResult.isValid) {
        errors.password = passwordResult.errors;
      }
    }

    // Phone validation (optional)
    if (data.phone) {
      const phoneResult = PhoneValidator.validate(data.phone);
      if (!phoneResult.isValid) {
        errors.phone = phoneResult.errors;
      }
    }

    // Terms acceptance
    if (!data.acceptTerms) {
      errors.acceptTerms = ['You must accept the terms and conditions'];
    }

    return {
      isValid: Object.keys(errors).length === 0,
      errors,
      data:
        Object.keys(errors).length === 0
          ? (data as RegistrationData)
          : undefined,
    };
  }

  async run(): Promise<TestResult> {
    const { result, duration } = await this.measure(async () => {
      const errors: string[] = [];
      let passed = 0;
      let failed = 0;

      // Test valid registrations
      for (const user of TestData.users.valid) {
        const result = this.validateRegistration({
          ...user,
          acceptTerms: true,
        });
        if (result.isValid) {
          passed++;
        } else {
          failed++;
          errors.push(
            `Valid user rejected: ${JSON.stringify(user)} - ${JSON.stringify(result.errors)}`,
          );
        }
      }

      // Test invalid registrations
      for (const testCase of TestData.users.invalid) {
        const result = this.validateRegistration({
          firstName: testCase.firstName,
          lastName: testCase.lastName,
          email: testCase.email,
          password: testCase.password,
          acceptTerms: true,
        });
        if (!result.isValid) {
          passed++;
        } else {
          failed++;
          errors.push(`Invalid user accepted: ${testCase.reason}`);
        }
      }

      // Test specific validation scenarios
      const scenarios = [
        {
          data: {
            firstName: '',
            lastName: 'Test',
            email: 'test@test.com',
            password: 'Test123!',
            acceptTerms: true,
          },
          shouldPass: false,
          reason: 'Empty first name',
        },
        {
          data: {
            firstName: 'Test',
            lastName: '',
            email: 'test@test.com',
            password: 'Test123!',
            acceptTerms: true,
          },
          shouldPass: false,
          reason: 'Empty last name',
        },
        {
          data: {
            firstName: 'Test',
            lastName: 'User',
            email: 'invalid',
            password: 'Test123!',
            acceptTerms: true,
          },
          shouldPass: false,
          reason: 'Invalid email',
        },
        {
          data: {
            firstName: 'Test',
            lastName: 'User',
            email: 'test@test.com',
            password: 'weak',
            acceptTerms: true,
          },
          shouldPass: false,
          reason: 'Weak password',
        },
        {
          data: {
            firstName: 'Test',
            lastName: 'User',
            email: 'test@test.com',
            password: 'Test123!',
            acceptTerms: false,
          },
          shouldPass: false,
          reason: 'Terms not accepted',
        },
        {
          data: {
            firstName: 'Jean-Pierre',
            lastName: "O'Connor",
            email: 'jean.pierre@email.fr',
            password: 'Str0ngP@ss!',
            phone: '+33612345678',
            acceptTerms: true,
          },
          shouldPass: true,
          reason: 'Valid user with special characters in name',
        },
      ];

      for (const scenario of scenarios) {
        const result = this.validateRegistration(scenario.data);
        if (result.isValid === scenario.shouldPass) {
          passed++;
        } else {
          failed++;
          errors.push(
            `Scenario failed: ${scenario.reason} - Expected ${scenario.shouldPass ? 'pass' : 'fail'}`,
          );
        }
      }

      return { passed, failed, errors };
    });

    if (result.failed === 0) {
      return {
        ...this.success(
          `All ${result.passed} registration validation tests passed`,
        ),
        duration,
        details: { passed: result.passed, failed: result.failed },
      };
    }

    return {
      ...this.failure(
        `${result.failed} registration validation tests failed`,
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
      const testType = Math.random() > 0.4 ? 'valid' : 'invalid';

      let data: Partial<RegistrationData>;
      let expectedValid: boolean;

      if (testType === 'valid') {
        // Generate valid registration data
        data = {
          firstName: randomString(
            8,
            'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ',
          ),
          lastName: randomString(
            10,
            'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ',
          ),
          email: randomEmail(),
          password: randomPassword('strong'),
          phone: randomPhone(),
          acceptTerms: true,
        };
        expectedValid = true;
      } else {
        // Generate invalid registration data
        const invalidType = Math.floor(Math.random() * 5);
        data = {
          firstName:
            invalidType === 0
              ? ''
              : randomString(5, 'abcdefghijklmnopqrstuvwxyz'),
          lastName:
            invalidType === 1
              ? ''
              : randomString(5, 'abcdefghijklmnopqrstuvwxyz'),
          email: invalidType === 2 ? 'invalid-email' : randomEmail(),
          password: invalidType === 3 ? 'weak' : randomPassword('strong'),
          acceptTerms: invalidType === 4 ? false : true,
        };
        expectedValid = false;
      }

      const result = this.validateRegistration(data);
      const testPassed = result.isValid === expectedValid;

      const testResult: TestResult = {
        name: `fuzzy_registration_${i + 1}`,
        passed: testPassed,
        message: testPassed
          ? `Registration validation (${testType}) passed correctly`
          : `Registration expected ${expectedValid ? 'valid' : 'invalid'}, got ${result.isValid ? 'valid' : 'invalid'}`,
        duration: 0,
        details: {
          testType,
          expectedValid,
          actualValid: result.isValid,
          errors: result.errors,
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
