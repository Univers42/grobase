import React from 'react';
import { render, fireEvent } from '@testing-library/react-native';
import { FormInput } from '../FormInput';

describe('FormInput', () => {
  it('renders label', () => {
    const { getByText } = render(<FormInput label="Email" value="" onChangeText={jest.fn()} />);
    expect(getByText('Email')).toBeTruthy();
  });

  it('renders input with value', () => {
    const { getByDisplayValue } = render(
      <FormInput label="Email" value="test@test.com" onChangeText={jest.fn()} />,
    );
    expect(getByDisplayValue('test@test.com')).toBeTruthy();
  });

  it('calls onChangeText when text changes', () => {
    const onChangeText = jest.fn();
    const { getByDisplayValue } = render(
      <FormInput label="Email" value="" onChangeText={onChangeText} />,
    );
    fireEvent.changeText(getByDisplayValue(''), 'new@email.com');
    expect(onChangeText).toHaveBeenCalledWith('new@email.com');
  });

  it('renders error message when provided', () => {
    const { getByText } = render(
      <FormInput label="Email" value="" onChangeText={jest.fn()} error="Invalid email" />,
    );
    expect(getByText('Invalid email')).toBeTruthy();
  });

  it('renders helper text when provided', () => {
    const { getByText } = render(
      <FormInput
        label="Password"
        value=""
        onChangeText={jest.fn()}
        helperText="Must be at least 8 characters"
      />,
    );
    expect(getByText('Must be at least 8 characters')).toBeTruthy();
  });

  it('applies secureTextEntry for password inputs', () => {
    const { getByTestId } = render(
      <FormInput
        label="Password"
        value=""
        onChangeText={jest.fn()}
        secureTextEntry
        testID="password-input"
      />,
    );
    const input = getByTestId('password-input');
    expect(input.props.secureTextEntry).toBe(true);
  });
});
