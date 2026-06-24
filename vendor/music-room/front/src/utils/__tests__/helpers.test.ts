import {
  debounce,
  throttle,
  stringToColor,
  truncate,
  capitalize,
  pluralize,
  generateId,
  clamp,
} from '../helpers';

describe('debounce', () => {
  jest.useFakeTimers();

  it('delays function execution', () => {
    const fn = jest.fn();
    const debounced = debounce(fn, 300);

    debounced();
    expect(fn).not.toHaveBeenCalled();

    jest.advanceTimersByTime(300);
    expect(fn).toHaveBeenCalledTimes(1);
  });

  it('resets timer on subsequent calls', () => {
    const fn = jest.fn();
    const debounced = debounce(fn, 300);

    debounced();
    jest.advanceTimersByTime(200);
    debounced(); // reset
    jest.advanceTimersByTime(200);
    expect(fn).not.toHaveBeenCalled();

    jest.advanceTimersByTime(100);
    expect(fn).toHaveBeenCalledTimes(1);
  });
});

describe('throttle', () => {
  jest.useFakeTimers();

  it('executes immediately on first call', () => {
    const fn = jest.fn();
    const throttled = throttle(fn, 300);

    throttled();
    expect(fn).toHaveBeenCalledTimes(1);
  });

  it('ignores calls within throttle period', () => {
    const fn = jest.fn();
    const throttled = throttle(fn, 300);

    throttled();
    throttled();
    throttled();
    expect(fn).toHaveBeenCalledTimes(1);
  });
});

describe('stringToColor', () => {
  it('returns consistent color for same string', () => {
    const color1 = stringToColor('alice');
    const color2 = stringToColor('alice');
    expect(color1).toBe(color2);
  });

  it('returns HSL color string', () => {
    const color = stringToColor('test');
    expect(color).toMatch(/^hsl\(\d+, 65%, 55%\)$/);
  });

  it('returns different colors for different strings', () => {
    const color1 = stringToColor('alice');
    const color2 = stringToColor('bob');
    expect(color1).not.toBe(color2);
  });
});

describe('truncate', () => {
  it('returns original if within limit', () => {
    expect(truncate('hello', 10)).toBe('hello');
  });

  it('truncates with ellipsis', () => {
    expect(truncate('hello world!', 8)).toBe('hello...');
  });
});

describe('capitalize', () => {
  it('capitalizes first letter', () => {
    expect(capitalize('hello')).toBe('Hello');
    expect(capitalize('WORLD')).toBe('World');
  });

  it('handles empty string', () => {
    expect(capitalize('')).toBe('');
  });
});

describe('pluralize', () => {
  it('returns singular for count of 1', () => {
    expect(pluralize(1, 'track')).toBe('1 track');
  });

  it('returns plural for other counts', () => {
    expect(pluralize(0, 'track')).toBe('0 tracks');
    expect(pluralize(5, 'track')).toBe('5 tracks');
  });

  it('uses custom plural form', () => {
    expect(pluralize(2, 'person', 'people')).toBe('2 people');
  });
});

describe('generateId', () => {
  it('returns string of correct format', () => {
    const id = generateId();
    expect(id).toMatch(/^[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}$/);
  });

  it('generates unique IDs', () => {
    const ids = new Set(Array.from({ length: 100 }, () => generateId()));
    expect(ids.size).toBeGreaterThan(90); // Allow some collisions in 100 tries
  });
});

describe('clamp', () => {
  it('clamps value between min and max', () => {
    expect(clamp(5, 0, 10)).toBe(5);
    expect(clamp(-1, 0, 10)).toBe(0);
    expect(clamp(15, 0, 10)).toBe(10);
  });
});
