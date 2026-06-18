/**
 * Quick Connection Test (Google OAuth)
 * Tests the Google OAuth integration flow validation
 */

import { BaseTest, TestResult, FuzzyTestResult } from './base.test';
import { EmailValidator } from '../validators';
import { randomString, randomEmail } from '../utils/test-data';

interface GoogleUserInfo {
  sub: string; // Google's unique user ID
  email: string;
  email_verified: boolean;
  name?: string;
  given_name?: string;
  family_name?: string;
  picture?: string;
  locale?: string;
}

interface OAuthTokenResponse {
  access_token: string;
  token_type: 'Bearer';
  expires_in: number;
  refresh_token?: string;
  scope: string;
  id_token?: string;
}

interface OAuthValidationResult {
  isValid: boolean;
  errors: string[];
  user?: GoogleUserInfo;
}

export class QuickConnectionTest extends BaseTest {
  name = 'quick_connection';
  description = 'Test Google OAuth quick connection flow (mock validation)';
  category = 'flow';

  /**
   * Validate OAuth token response format
   */
  private validateTokenResponse(token: Partial<OAuthTokenResponse>): {
    isValid: boolean;
    errors: string[];
  } {
    const errors: string[] = [];

    if (!token.access_token) {
      errors.push('Access token is required');
    } else if (token.access_token.length < 50) {
      errors.push('Access token format is invalid (too short)');
    }

    if (token.token_type !== 'Bearer') {
      errors.push('Token type must be Bearer');
    }

    if (!token.expires_in || token.expires_in <= 0) {
      errors.push('Token expiration is required and must be positive');
    }

    if (!token.scope || !token.scope.includes('email')) {
      errors.push('Scope must include email access');
    }

    return { isValid: errors.length === 0, errors };
  }

  /**
   * Validate Google user info response
   */
  private validateUserInfo(
    userInfo: Partial<GoogleUserInfo>,
  ): OAuthValidationResult {
    const errors: string[] = [];

    // Sub (unique ID) validation
    if (!userInfo.sub) {
      errors.push('Google user ID (sub) is required');
    } else if (userInfo.sub.length < 10) {
      errors.push('Invalid Google user ID format');
    }

    // Email validation
    if (!userInfo.email) {
      errors.push('Email is required from Google');
    } else {
      const emailResult = EmailValidator.validate(userInfo.email);
      if (!emailResult.isValid) {
        errors.push(...emailResult.errors.map((e) => `Email: ${e}`));
      }
    }

    // Email verified check
    if (!userInfo.email_verified) {
      errors.push('Email must be verified by Google');
    }

    return {
      isValid: errors.length === 0,
      errors,
      user: errors.length === 0 ? (userInfo as GoogleUserInfo) : undefined,
    };
  }

  /**
   * Generate mock Google user info
   */
  private generateMockGoogleUser(
    valid: boolean = true,
  ): Partial<GoogleUserInfo> {
    if (valid) {
      return {
        sub: randomString(21, '0123456789'),
        email: randomEmail(),
        email_verified: true,
        name: 'Jean Dupont',
        given_name: 'Jean',
        family_name: 'Dupont',
        picture: 'https://lh3.googleusercontent.com/a/default-user',
        locale: 'fr',
      };
    } else {
      const invalidType = Math.floor(Math.random() * 4);
      switch (invalidType) {
        case 0:
          return { email: randomEmail(), email_verified: true }; // Missing sub
        case 1:
          return { sub: randomString(21, '0123456789'), email_verified: true }; // Missing email
        case 2:
          return {
            sub: randomString(21, '0123456789'),
            email: randomEmail(),
            email_verified: false,
          }; // Unverified
        default:
          return {
            sub: randomString(21, '0123456789'),
            email: 'invalid-email',
            email_verified: true,
          }; // Bad email
      }
    }
  }

  /**
   * Generate mock OAuth token response
   */
  private generateMockTokenResponse(
    valid: boolean = true,
  ): Partial<OAuthTokenResponse> {
    if (valid) {
      return {
        access_token: randomString(
          100,
          'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-',
        ),
        token_type: 'Bearer',
        expires_in: 3600,
        scope: 'openid email profile',
        id_token: randomString(
          200,
          'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-',
        ),
      };
    } else {
      const invalidType = Math.floor(Math.random() * 4);
      switch (invalidType) {
        case 0:
          return { token_type: 'Bearer', expires_in: 3600, scope: 'email' }; // Missing token
        case 1:
          return {
            access_token: 'short',
            token_type: 'Bearer',
            expires_in: 3600,
            scope: 'email',
          }; // Short token
        case 2:
          return {
            access_token: randomString(100),
            token_type: 'Basic' as 'Bearer',
            expires_in: 3600,
            scope: 'email',
          }; // Wrong type
        default:
          return {
            access_token: randomString(100),
            token_type: 'Bearer',
            expires_in: 3600,
            scope: 'profile',
          }; // Missing email scope
      }
    }
  }

  async run(): Promise<TestResult> {
    const { result, duration } = await this.measure(async () => {
      const errors: string[] = [];
      let passed = 0;
      let failed = 0;

      // ===== Token Response Validation =====

      // Valid token responses
      for (let i = 0; i < 5; i++) {
        const token = this.generateMockTokenResponse(true);
        const result = this.validateTokenResponse(token);
        if (result.isValid) {
          passed++;
        } else {
          failed++;
          errors.push(`Valid token rejected: ${result.errors.join(', ')}`);
        }
      }

      // Invalid token responses
      for (let i = 0; i < 5; i++) {
        const token = this.generateMockTokenResponse(false);
        const result = this.validateTokenResponse(token);
        if (!result.isValid) {
          passed++;
        } else {
          failed++;
          errors.push('Invalid token accepted');
        }
      }

      // ===== User Info Validation =====

      // Valid user info
      for (let i = 0; i < 5; i++) {
        const user = this.generateMockGoogleUser(true);
        const result = this.validateUserInfo(user);
        if (result.isValid) {
          passed++;
        } else {
          failed++;
          errors.push(`Valid user rejected: ${result.errors.join(', ')}`);
        }
      }

      // Invalid user info
      for (let i = 0; i < 5; i++) {
        const user = this.generateMockGoogleUser(false);
        const result = this.validateUserInfo(user);
        if (!result.isValid) {
          passed++;
        } else {
          failed++;
          errors.push('Invalid user info accepted');
        }
      }

      // ===== Complete OAuth Flow Simulation =====
      const simulateOAuthFlow = () => {
        // Step 1: Authorization redirect (simulated)
        // In real OAuth, this code would be exchanged for tokens
        // eslint-disable-next-line @typescript-eslint/no-unused-vars
        const authorizationCode = randomString(64);

        // Step 2: Token exchange
        const tokenResponse = this.generateMockTokenResponse(true);
        const tokenValidation = this.validateTokenResponse(tokenResponse);
        if (!tokenValidation.isValid)
          return { success: false, error: 'Token validation failed' };

        // Step 3: Get user info
        const userInfo = this.generateMockGoogleUser(true);
        const userValidation = this.validateUserInfo(userInfo);
        if (!userValidation.isValid)
          return { success: false, error: 'User validation failed' };

        // Step 4: Create or link local account
        // (In real implementation, this would check DB and create/link user)

        return { success: true, user: userValidation.user };
      };

      // Test complete flow multiple times
      for (let i = 0; i < 5; i++) {
        const flowResult = simulateOAuthFlow();
        if (flowResult.success) {
          passed++;
        } else {
          failed++;
          errors.push(`OAuth flow failed: ${flowResult.error}`);
        }
      }

      // ===== Edge Cases =====

      // Test with special email domains
      const specialEmails = [
        {
          sub: '123456789012345678901',
          email: 'user@gmail.com',
          email_verified: true,
        },
        {
          sub: '123456789012345678901',
          email: 'user@googlemail.com',
          email_verified: true,
        },
        {
          sub: '123456789012345678901',
          email: 'user.name+tag@gmail.com',
          email_verified: true,
        },
      ];

      for (const user of specialEmails) {
        const result = this.validateUserInfo(user);
        if (result.isValid) {
          passed++;
        } else {
          failed++;
          errors.push(`Special email rejected: ${user.email}`);
        }
      }

      return { passed, failed, errors };
    });

    if (result.failed === 0) {
      return {
        ...this.success(`All ${result.passed} OAuth validation tests passed`),
        duration,
        details: { passed: result.passed, failed: result.failed },
      };
    }

    return {
      ...this.failure(
        `${result.failed} OAuth validation tests failed`,
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
      const component = Math.random() > 0.5 ? 'token' : 'user';

      let testPassed: boolean;
      let message: string;
      let details: Record<string, unknown> = {};

      if (component === 'token') {
        const token = this.generateMockTokenResponse(testType === 'valid');
        const result = this.validateTokenResponse(token);
        const expectedValid = testType === 'valid';
        testPassed = result.isValid === expectedValid;
        message = `Token validation (${testType}): ${testPassed ? 'correct' : 'incorrect'}`;
        details = {
          expectedValid,
          actualValid: result.isValid,
          errors: result.errors,
        };
      } else {
        const user = this.generateMockGoogleUser(testType === 'valid');
        const result = this.validateUserInfo(user);
        const expectedValid = testType === 'valid';
        testPassed = result.isValid === expectedValid;
        message = `User info validation (${testType}): ${testPassed ? 'correct' : 'incorrect'}`;
        details = {
          expectedValid,
          actualValid: result.isValid,
          errors: result.errors,
        };
      }

      const testResult: TestResult = {
        name: `fuzzy_oauth_${i + 1}`,
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
