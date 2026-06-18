import { TrimPipe } from '../trim.pipe';

describe('TrimPipe', () => {
  let pipe: TrimPipe;

  beforeEach(() => {
    pipe = new TrimPipe();
  });

  it('should trim strings', () => {
    expect(pipe.transform('  hello  ')).toBe('hello');
  });

  it('should trim string values in objects', () => {
    const result = pipe.transform({ name: '  John  ', age: 25 });
    expect(result).toEqual({ name: 'John', age: 25 });
  });

  it('should handle nested objects', () => {
    const result = pipe.transform({ user: { name: '  Jane  ' } });
    expect(result).toEqual({ user: { name: 'Jane' } });
  });

  it('should trim strings in arrays', () => {
    const result = pipe.transform({ tags: ['  rock  ', '  pop  '] });
    expect(result).toEqual({ tags: ['rock', 'pop'] });
  });

  it('should preserve numbers', () => {
    expect(pipe.transform(42)).toBe(42);
  });

  it('should preserve null', () => {
    expect(pipe.transform(null)).toBeNull();
  });

  it('should preserve boolean values', () => {
    expect(pipe.transform(true)).toBe(true);
    expect(pipe.transform(false)).toBe(false);
  });
});
