import {
  isValidEmail,
  isStrongPassword,
  getPasswordStrength,
  isValidUsername,
  isRequired,
  hasMinLength,
  hasMaxLength,
} from '../validators';

describe('isValidEmail', () => {
  it('accepts valid emails', () => {
    expect(isValidEmail('test@test.com')).toBe(true);
    expect(isValidEmail('user.name+tag@example.com')).toBe(true);
    expect(isValidEmail('user@sub.domain.com')).toBe(true);
  });

  it('rejects invalid emails', () => {
    expect(isValidEmail('')).toBe(false);
    expect(isValidEmail('not-an-email')).toBe(false);
    expect(isValidEmail('@missing.local')).toBe(false);
    expect(isValidEmail('missing@')).toBe(false);
    expect(isValidEmail('has space@test.com')).toBe(false);
  });
});

describe('isStrongPassword', () => {
  it('accepts strong passwords', () => {
    expect(isStrongPassword('MyP@ss123!')).toBe(true);
    expect(isStrongPassword('Str0ng!Password')).toBe(true);
  });

  it('rejects weak passwords', () => {
    expect(isStrongPassword('short')).toBe(false);
    expect(isStrongPassword('nouppercase1!')).toBe(false);
    expect(isStrongPassword('NOLOWERCASE1!')).toBe(false);
    expect(isStrongPassword('NoDigits!!')).toBe(false);
    expect(isStrongPassword('NoSpecial123')).toBe(false);
  });
});

describe('getPasswordStrength', () => {
  it('returns low score for weak passwords', () => {
    const result = getPasswordStrength('abc');
    expect(result.score).toBeLessThan(3);
    expect(result.suggestions.length).toBeGreaterThan(0);
  });

  it('returns high score for strong passwords', () => {
    const result = getPasswordStrength('MyStr0ngP@ssword!');
    expect(result.score).toBeGreaterThan(4);
  });

  it('includes color and label', () => {
    const result = getPasswordStrength('test');
    expect(result.color).toBeTruthy();
    expect(result.label).toBeTruthy();
  });
});

describe('isValidUsername', () => {
  it('accepts valid usernames', () => {
    expect(isValidUsername('alice')).toBe(true);
    expect(isValidUsername('user_name')).toBe(true);
    expect(isValidUsername('user-123')).toBe(true);
  });

  it('rejects invalid usernames', () => {
    expect(isValidUsername('ab')).toBe(false); // too short
    expect(isValidUsername('a'.repeat(31))).toBe(false); // too long
    expect(isValidUsername('has space')).toBe(false);
    expect(isValidUsername('special@char')).toBe(false);
  });
});

describe('isRequired', () => {
  it('returns true for non-empty strings', () => {
    expect(isRequired('hello')).toBe(true);
  });

  it('returns false for empty/null/undefined', () => {
    expect(isRequired('')).toBe(false);
    expect(isRequired('   ')).toBe(false);
    expect(isRequired(null)).toBe(false);
    expect(isRequired(undefined)).toBe(false);
  });
});

describe('hasMinLength', () => {
  it('validates minimum length', () => {
    expect(hasMinLength('hello', 3)).toBe(true);
    expect(hasMinLength('hi', 3)).toBe(false);
  });
});

describe('hasMaxLength', () => {
  it('validates maximum length', () => {
    expect(hasMaxLength('hi', 5)).toBe(true);
    expect(hasMaxLength('hello world', 5)).toBe(false);
  });
});
