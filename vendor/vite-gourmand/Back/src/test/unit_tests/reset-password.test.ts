/**
 * Reset Password Test
 * Tests the password reset flow validation
 */

import { BaseTest, TestResult, FuzzyTestResult } from './base.test';
import { EmailValidator, PasswordValidator } from '../validators';
import { randomEmail, randomPassword, randomString } from '../utils/test-data';

interface ResetPasswordRequest {
  email: string;
}

interface ResetPasswordConfirm {
  token: string;
  newPassword: string;
  confirmPassword: string;
}

interface ResetValidationResult {
  isValid: boolean;
  errors: string[];
}

export class ResetPasswordTest extends BaseTest {
  name = 'reset_password';
  description = 'Test password reset flow validation (request + confirmation)';
  category = 'flow';

  /**
   * Validate password reset request (step 1)
   */
  private validateResetRequest(
    data: ResetPasswordRequest,
  ): ResetValidationResult {
    const errors: string[] = [];

    if (!data.email) {
      errors.push('Email is required');
    } else {
      const emailResult = EmailValidator.validate(data.email);
      if (!emailResult.isValid) {
        errors.push(...emailResult.errors);
      }
    }

    return { isValid: errors.length === 0, errors };
  }

  /**
   * Validate password reset confirmation (step 2)
   */
  private validateResetConfirm(
    data: ResetPasswordConfirm,
  ): ResetValidationResult {
    const errors: string[] = [];

    // Token validation
    if (!data.token) {
      errors.push('Reset token is required');
    } else if (data.token.length < 32) {
      errors.push('Invalid reset token format');
    } else if (!/^[a-zA-Z0-9]+$/.test(data.token)) {
      errors.push('Reset token contains invalid characters');
    }

    // New password validation
    if (!data.newPassword) {
      errors.push('New password is required');
    } else {
      const passwordResult = PasswordValidator.validate(data.newPassword);
      if (!passwordResult.isValid) {
        errors.push(...passwordResult.errors);
      }
    }

    // Confirm password validation
    if (!data.confirmPassword) {
      errors.push('Password confirmation is required');
    } else if (data.newPassword !== data.confirmPassword) {
      errors.push('Passwords do not match');
    }

    return { isValid: errors.length === 0, errors };
  }

  /**
   * Generate a valid reset token (mock)
   */
  private generateResetToken(): string {
    return randomString(
      64,
      'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789',
    );
  }

  async run(): Promise<TestResult> {
    const { result, duration } = await this.measure(async () => {
      const errors: string[] = [];
      let passed = 0;
      let failed = 0;

      // ===== STEP 1: Request password reset =====

      // Valid reset requests
      const validEmails = [
        'user@example.com',
        'admin@vitegourmand.fr',
        'test.user@gmail.com',
      ];
      for (const email of validEmails) {
        const result = this.validateResetRequest({ email });
        if (result.isValid) {
          passed++;
        } else {
          failed++;
          errors.push(`Valid email rejected: ${email}`);
        }
      }

      // Invalid reset requests
      const invalidEmails = ['', 'invalid', '@missing.com', 'no@tld'];
      for (const email of invalidEmails) {
        const result = this.validateResetRequest({ email });
        if (!result.isValid) {
          passed++;
        } else {
          failed++;
          errors.push(`Invalid email accepted: ${email}`);
        }
      }

      // ===== STEP 2: Confirm password reset =====

      // Valid reset confirmations
      const validConfirmations = [
        {
          token: this.generateResetToken(),
          newPassword: 'NewSecureP@ss123!',
          confirmPassword: 'NewSecureP@ss123!',
        },
        {
          token: this.generateResetToken(),
          newPassword: 'AnotherG00d!Pass',
          confirmPassword: 'AnotherG00d!Pass',
        },
      ];

      for (const confirm of validConfirmations) {
        const result = this.validateResetConfirm(confirm);
        if (result.isValid) {
          passed++;
        } else {
          failed++;
          errors.push(
            `Valid confirmation rejected: ${result.errors.join(', ')}`,
          );
        }
      }

      // Invalid reset confirmations
      const invalidConfirmations = [
        {
          data: {
            token: '',
            newPassword: 'Test123!',
            confirmPassword: 'Test123!',
          },
          reason: 'Empty token',
        },
        {
          data: {
            token: 'short',
            newPassword: 'Test123!',
            confirmPassword: 'Test123!',
          },
          reason: 'Token too short',
        },
        {
          data: {
            token: 'invalid@token!',
            newPassword: 'Test123!',
            confirmPassword: 'Test123!',
          },
          reason: 'Invalid token characters',
        },
        {
          data: {
            token: this.generateResetToken(),
            newPassword: 'weak',
            confirmPassword: 'weak',
          },
          reason: 'Weak password',
        },
        {
          data: {
            token: this.generateResetToken(),
            newPassword: 'Test123!',
            confirmPassword: 'Different456!',
          },
          reason: 'Passwords do not match',
        },
        {
          data: {
            token: this.generateResetToken(),
            newPassword: '',
            confirmPassword: '',
          },
          reason: 'Empty passwords',
        },
      ];

      for (const confirm of invalidConfirmations) {
        const result = this.validateResetConfirm(confirm.data);
        if (!result.isValid) {
          passed++;
        } else {
          failed++;
          errors.push(`Invalid confirmation accepted: ${confirm.reason}`);
        }
      }

      // ===== Complete flow simulation =====
      const completeFlow = async () => {
        // Step 1: Request reset
        const requestResult = this.validateResetRequest({
          email: 'user@example.com',
        });
        if (!requestResult.isValid) return false;

        // Simulate token generation (in real app, sent via email)
        const token = this.generateResetToken();

        // Step 2: Confirm reset
        const confirmResult = this.validateResetConfirm({
          token,
          newPassword: 'NewSecureP@ssw0rd!',
          confirmPassword: 'NewSecureP@ssw0rd!',
        });

        return confirmResult.isValid;
      };

      const flowResult = await completeFlow();
      if (flowResult) {
        passed++;
      } else {
        failed++;
        errors.push('Complete flow validation failed');
      }

      return { passed, failed, errors };
    });

    if (result.failed === 0) {
      return {
        ...this.success(
          `All ${result.passed} password reset validation tests passed`,
        ),
        duration,
        details: { passed: result.passed, failed: result.failed },
      };
    }

    return {
      ...this.failure(
        `${result.failed} password reset validation tests failed`,
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
      const step = Math.random() > 0.5 ? 'request' : 'confirm';

      let testPassed: boolean;
      let message: string;
      let details: Record<string, unknown> = {};

      if (step === 'request') {
        const email = testType === 'valid' ? randomEmail() : randomString(10);
        const result = this.validateResetRequest({ email });
        const expectedValid = testType === 'valid';
        testPassed = result.isValid === expectedValid;
        message = `Reset request (${testType}): ${testPassed ? 'correct' : 'incorrect'}`;
        details = {
          email,
          expectedValid,
          actualValid: result.isValid,
          errors: result.errors,
        };
      } else {
        const token =
          testType === 'valid' ? this.generateResetToken() : randomString(10);
        const password =
          testType === 'valid'
            ? randomPassword('strong')
            : randomPassword('weak');
        const confirmPassword =
          testType === 'valid' ? password : randomPassword('weak');

        const result = this.validateResetConfirm({
          token,
          newPassword: password,
          confirmPassword,
        });
        const expectedValid = testType === 'valid';
        testPassed = result.isValid === expectedValid;
        message = `Reset confirm (${testType}): ${testPassed ? 'correct' : 'incorrect'}`;
        details = {
          expectedValid,
          actualValid: result.isValid,
          errors: result.errors,
        };
      }

      const testResult: TestResult = {
        name: `fuzzy_reset_password_${i + 1}`,
        passed: testPassed,
        message,
        duration: 0,
        details,
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
