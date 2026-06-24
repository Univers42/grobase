import { renderHook, act } from '@testing-library/react-hooks';
import { useForm } from '../useForm';

describe('useForm', () => {
  const initialValues = {
    email: '',
    password: '',
    username: '',
  };

  const validate = (values: typeof initialValues) => {
    const errors: Partial<Record<keyof typeof initialValues, string>> = {};
    if (!values.email) errors.email = 'Email is required';
    if (!values.email.includes('@')) errors.email = 'Invalid email';
    if (values.password.length < 8) errors.password = 'Min 8 characters';
    return errors;
  };

  it('initializes with given values', () => {
    const { result } = renderHook(() =>
      useForm({ initialValues, validate, onSubmit: jest.fn() }),
    );
    expect(result.current.values).toEqual(initialValues);
    expect(result.current.errors).toEqual({});
  });

  it('updates values on change', () => {
    const { result } = renderHook(() =>
      useForm({ initialValues, validate, onSubmit: jest.fn() }),
    );

    act(() => {
      result.current.handleChange('email', 'test@test.com');
    });

    expect(result.current.values.email).toBe('test@test.com');
  });

  it('validates on submit', () => {
    const onSubmit = jest.fn();
    const { result } = renderHook(() =>
      useForm({ initialValues, validate, onSubmit }),
    );

    act(() => {
      result.current.handleSubmit();
    });

    expect(onSubmit).not.toHaveBeenCalled();
    expect(result.current.errors.email).toBeTruthy();
    expect(result.current.errors.password).toBeTruthy();
  });

  it('calls onSubmit when validation passes', () => {
    const onSubmit = jest.fn();
    const { result } = renderHook(() =>
      useForm({ initialValues, validate, onSubmit }),
    );

    act(() => {
      result.current.handleChange('email', 'test@test.com');
      result.current.handleChange('password', 'strongpassword');
    });

    act(() => {
      result.current.handleSubmit();
    });

    expect(onSubmit).toHaveBeenCalledWith({
      email: 'test@test.com',
      password: 'strongpassword',
      username: '',
    });
  });

  it('resets form to initial values', () => {
    const { result } = renderHook(() =>
      useForm({ initialValues, validate, onSubmit: jest.fn() }),
    );

    act(() => {
      result.current.handleChange('email', 'test@test.com');
    });

    act(() => {
      result.current.reset();
    });

    expect(result.current.values).toEqual(initialValues);
    expect(result.current.errors).toEqual({});
  });
});
