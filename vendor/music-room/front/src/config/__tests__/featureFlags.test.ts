import {
  getFeatureFlags,
  isFeatureEnabled,
  setFeatureFlags,
  resetFeatureFlags,
} from '../featureFlags';

describe('featureFlags', () => {
  beforeEach(() => {
    resetFeatureFlags();
  });

  it('returns default flags', () => {
    const flags = getFeatureFlags();
    expect(flags.enableVoting).toBe(true);
    expect(flags.enableIoT).toBe(false);
    expect(flags.enableOfflineMode).toBe(true);
  });

  it('checks individual feature', () => {
    expect(isFeatureEnabled('enableVoting')).toBe(true);
    expect(isFeatureEnabled('enableIoT')).toBe(false);
  });

  it('updates feature flags', () => {
    setFeatureFlags({ enableIoT: true });
    expect(isFeatureEnabled('enableIoT')).toBe(true);
    // Other flags unchanged
    expect(isFeatureEnabled('enableVoting')).toBe(true);
  });

  it('resets to defaults', () => {
    setFeatureFlags({ enableVoting: false, enableIoT: true });
    resetFeatureFlags();
    expect(isFeatureEnabled('enableVoting')).toBe(true);
    expect(isFeatureEnabled('enableIoT')).toBe(false);
  });

  it('returns a copy of flags (immutable)', () => {
    const flags1 = getFeatureFlags();
    flags1.enableVoting = false;
    const flags2 = getFeatureFlags();
    expect(flags2.enableVoting).toBe(true);
  });
});
