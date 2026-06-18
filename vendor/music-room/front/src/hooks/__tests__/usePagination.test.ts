import { renderHook, act } from '@testing-library/react-hooks';
import { usePagination } from '../usePagination';

describe('usePagination', () => {
  it('initializes with page 1', () => {
    const { result } = renderHook(() =>
      usePagination({ totalItems: 100, itemsPerPage: 10 }),
    );
    expect(result.current.currentPage).toBe(1);
    expect(result.current.totalPages).toBe(10);
  });

  it('goes to next page', () => {
    const { result } = renderHook(() =>
      usePagination({ totalItems: 50, itemsPerPage: 10 }),
    );

    act(() => result.current.nextPage());
    expect(result.current.currentPage).toBe(2);
  });

  it('goes to previous page', () => {
    const { result } = renderHook(() =>
      usePagination({ totalItems: 50, itemsPerPage: 10 }),
    );

    act(() => result.current.nextPage());
    act(() => result.current.nextPage());
    act(() => result.current.prevPage());
    expect(result.current.currentPage).toBe(2);
  });

  it('cannot go below page 1', () => {
    const { result } = renderHook(() =>
      usePagination({ totalItems: 50, itemsPerPage: 10 }),
    );

    act(() => result.current.prevPage());
    expect(result.current.currentPage).toBe(1);
  });

  it('cannot go beyond total pages', () => {
    const { result } = renderHook(() =>
      usePagination({ totalItems: 30, itemsPerPage: 10 }),
    );

    act(() => result.current.goToPage(5));
    expect(result.current.currentPage).toBe(3);
  });

  it('calculates hasNext and hasPrev correctly', () => {
    const { result } = renderHook(() =>
      usePagination({ totalItems: 20, itemsPerPage: 10 }),
    );

    expect(result.current.hasPrev).toBe(false);
    expect(result.current.hasNext).toBe(true);

    act(() => result.current.nextPage());
    expect(result.current.hasPrev).toBe(true);
    expect(result.current.hasNext).toBe(false);
  });

  it('resets to page 1', () => {
    const { result } = renderHook(() =>
      usePagination({ totalItems: 100, itemsPerPage: 10 }),
    );

    act(() => result.current.goToPage(5));
    act(() => result.current.reset());
    expect(result.current.currentPage).toBe(1);
  });
});
