import { renderHook, act } from '@testing-library/react-hooks';
import { useDebounce } from '../useDebounce';

jest.useFakeTimers();

describe('useDebounce', () => {
  it('returns initial value immediately', () => {
    const { result } = renderHook(() => useDebounce('hello', 500));
    expect(result.current).toBe('hello');
  });

  it('debounces value updates', () => {
    const { result, rerender } = renderHook(
      ({ value, delay }) => useDebounce(value, delay),
      { initialProps: { value: 'hello', delay: 500 } },
    );

    rerender({ value: 'world', delay: 500 });
    expect(result.current).toBe('hello');

    act(() => {
      jest.advanceTimersByTime(500);
    });

    expect(result.current).toBe('world');
  });

  it('resets timer on rapid updates', () => {
    const { result, rerender } = renderHook(
      ({ value, delay }) => useDebounce(value, delay),
      { initialProps: { value: 'a', delay: 300 } },
    );

    rerender({ value: 'ab', delay: 300 });
    act(() => jest.advanceTimersByTime(200));

    rerender({ value: 'abc', delay: 300 });
    act(() => jest.advanceTimersByTime(200));

    expect(result.current).toBe('a');

    act(() => jest.advanceTimersByTime(300));
    expect(result.current).toBe('abc');
  });
});
