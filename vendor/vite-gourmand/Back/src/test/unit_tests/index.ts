/**
 * Tests Index
 * Export all test classes and register them
 */

export { BaseTest, TestRegistry } from './base.test';
export type { TestResult, FuzzyTestResult, TestConfig } from './base.test';
export { EmailValidationTest } from './email-validation.test';
export { VerifyCreditCardTest } from './verify-credit-card.test';
export { PasswordStrengthTest } from './password-strength.test';
export { FirstTimeRegistrationTest } from './first-time-registration.test';
export { ResetPasswordTest } from './reset-password.test';
export { QuickConnectionTest } from './quick-connection.test';
export { DbMailConnectionTest } from './db-mail-connection.test';
