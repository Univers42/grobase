/**
 * Password Strength Test
 * Tests password validation and strength scoring
 */

import { BaseTest, TestResult, FuzzyTestResult } from './base.test';
import { PasswordValidator } from '../validators';
import { TestData, randomPassword } from '../utils/test-data';

export class PasswordStrengthTest extends BaseTest {
  name = 'password_strength';
  description = 'Test password strength validation and entropy calculation';
  category = 'validation';

  async run(): Promise<TestResult> {
    const { result, duration } = await this.measure(async () => {
      const errors: string[] = [];
      let passed = 0;
      let failed = 0;

      // Test strong passwords - should be valid
      for (const test of TestData.passwords.strong) {
        const validation = PasswordValidator.validate(test.password);
        if (validation.isValid && validation.score >= 4) {
          passed++;
        } else {
          failed++;
          errors.push(
            `Strong password failed: '${test.password}' (${test.reason}) - Score: ${validation.score}`,
          );
        }
      }

      // Test medium passwords - should have score 2-3
      for (const test of TestData.passwords.medium) {
        const validation = PasswordValidator.validate(test.password, {
          minScore: 1,
        });
        if (validation.score >= 2 && validation.score <= 4) {
          passed++;
        } else {
          failed++;
          errors.push(
            `Medium password unexpected score: '${test.password}' (${test.reason}) - Score: ${validation.score}, Expected: 2-3`,
          );
        }
      }

      // Test weak passwords - should not be valid
      for (const test of TestData.passwords.weak) {
        const validation = PasswordValidator.validate(test.password);
        if (!validation.isValid || validation.score <= 2) {
          passed++;
        } else {
          failed++;
          errors.push(
            `Weak password passed unexpectedly: '${test.password}' (${test.reason}) - Score: ${validation.score}`,
          );
        }
      }

      // Test blacklisted passwords
      for (const password of TestData.passwords.blacklist.slice(0, 10)) {
        const validation = PasswordValidator.validate(password);
        if (!validation.criteria.notInBlacklist) {
          passed++;
        } else {
          failed++;
          errors.push(`Blacklisted password not detected: '${password}'`);
        }
      }

      // Test entropy calculation
      const entropyTests = [
        { password: 'abc', minEntropy: 5, maxEntropy: 15 },
        { password: 'Abc123', minEntropy: 25, maxEntropy: 40 },
        { password: 'Abc123!@#', minEntropy: 45, maxEntropy: 60 },
        { password: 'MySecureP@ssw0rd!', minEntropy: 80, maxEntropy: 120 },
      ];

      for (const test of entropyTests) {
        const validation = PasswordValidator.validate(test.password);
        if (
          validation.entropy >= test.minEntropy &&
          validation.entropy <= test.maxEntropy
        ) {
          passed++;
        } else {
          failed++;
          errors.push(
            `Entropy for '${test.password}': ${validation.entropy} bits, expected ${test.minEntropy}-${test.maxEntropy}`,
          );
        }
      }

      // Test password generation
      for (let i = 0; i < 5; i++) {
        const generated = PasswordValidator.generate(16);
        const validation = PasswordValidator.validate(generated);
        if (validation.isValid && validation.score >= 4) {
          passed++;
        } else {
          failed++;
          errors.push(
            `Generated password not strong enough: Score ${validation.score}`,
          );
        }
      }

      // Test crack time estimation
      const validation = PasswordValidator.validate('MySecureP@ssw0rd!');
      if (
        validation.crackTime.online !== 'instantly' &&
        validation.crackTime.offlineFast !== 'instantly'
      ) {
        passed++;
      } else {
        failed++;
        errors.push('Strong password should not crack instantly');
      }

      return { passed, failed, errors };
    });

    if (result.failed === 0) {
      return {
        ...this.success(`All ${result.passed} password strength tests passed`),
        duration,
        details: { passed: result.passed, failed: result.failed },
      };
    }

    return {
      ...this.failure(
        `${result.failed} password strength tests failed`,
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
      const strength = (['weak', 'medium', 'strong'] as const)[
        Math.floor(Math.random() * 3)
      ];
      const password = randomPassword(strength);

      const validation = PasswordValidator.validate(password);

      // Validate that the strength matches expectations
      let expectedMinScore: number;
      let expectedMaxScore: number;

      switch (strength) {
        case 'weak':
          expectedMinScore = 0;
          expectedMaxScore = 2;
          break;
        case 'medium':
          expectedMinScore = 2;
          expectedMaxScore = 4;
          break;
        case 'strong':
          expectedMinScore = 3;
          expectedMaxScore = 5;
          break;
      }

      const testPassed =
        validation.score >= expectedMinScore &&
        validation.score <= expectedMaxScore;

      const testResult: TestResult = {
        name: `fuzzy_password_${i + 1}`,
        passed: testPassed,
        message: testPassed
          ? `Password strength '${strength}' validated correctly (score: ${validation.score})`
          : `Password strength mismatch: generated '${strength}', got score ${validation.score} (expected ${expectedMinScore}-${expectedMaxScore})`,
        duration: 0,
        details: {
          strength,
          score: validation.score,
          actualStrength: validation.strength,
          entropy: validation.entropy,
          expectedRange: `${expectedMinScore}-${expectedMaxScore}`,
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
