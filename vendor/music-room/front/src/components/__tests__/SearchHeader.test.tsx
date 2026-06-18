import React from 'react';
import { render, fireEvent } from '@testing-library/react-native';
import { SearchHeader } from '../SearchHeader';

describe('SearchHeader', () => {
  it('renders search input', () => {
    const { getByPlaceholderText } = render(
      <SearchHeader value="" onChangeText={jest.fn()} placeholder="Search tracks..." />,
    );
    expect(getByPlaceholderText('Search tracks...')).toBeTruthy();
  });

  it('calls onChangeText when text changes', () => {
    const onChangeText = jest.fn();
    const { getByPlaceholderText } = render(
      <SearchHeader value="" onChangeText={onChangeText} placeholder="Search..." />,
    );
    fireEvent.changeText(getByPlaceholderText('Search...'), 'queen');
    expect(onChangeText).toHaveBeenCalledWith('queen');
  });

  it('renders clear button when value is not empty', () => {
    const { getByTestId } = render(
      <SearchHeader value="test" onChangeText={jest.fn()} placeholder="Search..." />,
    );
    expect(getByTestId('clear-button')).toBeTruthy();
  });

  it('clears input when clear button is pressed', () => {
    const onChangeText = jest.fn();
    const { getByTestId } = render(
      <SearchHeader value="test" onChangeText={onChangeText} placeholder="Search..." />,
    );
    fireEvent.press(getByTestId('clear-button'));
    expect(onChangeText).toHaveBeenCalledWith('');
  });
});
