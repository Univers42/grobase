import { renderHook, act } from '@testing-library/react-hooks';
import { useCountdown } from '../useCountdown';

jest.useFakeTimers();

describe('useCountdown', () => {
  it('initializes with the given count', () => {
    const { result } = renderHook(() => useCountdown(10));
    expect(result.current.count).toBe(10);
    expect(result.current.isRunning).toBe(false);
  });

  it('starts countdown when start is called', () => {
    const { result } = renderHook(() => useCountdown(5));

    act(() => {
      result.current.start();
    });

    expect(result.current.isRunning).toBe(true);

    act(() => {
      jest.advanceTimersByTime(1000);
    });

    expect(result.current.count).toBe(4);
  });

  it('stops at zero', () => {
    const { result } = renderHook(() => useCountdown(2));

    act(() => {
      result.current.start();
    });

    act(() => {
      jest.advanceTimersByTime(3000);
    });

    expect(result.current.count).toBe(0);
    expect(result.current.isRunning).toBe(false);
  });

  it('can be paused and resumed', () => {
    const { result } = renderHook(() => useCountdown(10));

    act(() => result.current.start());
    act(() => jest.advanceTimersByTime(3000));
    expect(result.current.count).toBe(7);

    act(() => result.current.pause());
    act(() => jest.advanceTimersByTime(2000));
    expect(result.current.count).toBe(7);

    act(() => result.current.start());
    act(() => jest.advanceTimersByTime(2000));
    expect(result.current.count).toBe(5);
  });

  it('can be reset', () => {
    const { result } = renderHook(() => useCountdown(10));

    act(() => result.current.start());
    act(() => jest.advanceTimersByTime(5000));
    expect(result.current.count).toBe(5);

    act(() => result.current.reset());
    expect(result.current.count).toBe(10);
    expect(result.current.isRunning).toBe(false);
  });
});
