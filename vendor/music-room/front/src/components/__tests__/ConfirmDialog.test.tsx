import React from 'react';
import { render, fireEvent } from '@testing-library/react-native';
import { ConfirmDialog } from '../ConfirmDialog';

describe('ConfirmDialog', () => {
  const defaultProps = {
    visible: true,
    title: 'Delete Event',
    message: 'Are you sure you want to delete this event?',
    onConfirm: jest.fn(),
    onCancel: jest.fn(),
  };

  it('renders title and message when visible', () => {
    const { getByText } = render(<ConfirmDialog {...defaultProps} />);
    expect(getByText('Delete Event')).toBeTruthy();
    expect(getByText('Are you sure you want to delete this event?')).toBeTruthy();
  });

  it('does not render when not visible', () => {
    const { queryByText } = render(<ConfirmDialog {...defaultProps} visible={false} />);
    expect(queryByText('Delete Event')).toBeNull();
  });

  it('calls onConfirm when confirm button is pressed', () => {
    const onConfirm = jest.fn();
    const { getByText } = render(<ConfirmDialog {...defaultProps} onConfirm={onConfirm} />);
    fireEvent.press(getByText('Confirm'));
    expect(onConfirm).toHaveBeenCalledTimes(1);
  });

  it('calls onCancel when cancel button is pressed', () => {
    const onCancel = jest.fn();
    const { getByText } = render(<ConfirmDialog {...defaultProps} onCancel={onCancel} />);
    fireEvent.press(getByText('Cancel'));
    expect(onCancel).toHaveBeenCalledTimes(1);
  });

  it('renders custom button labels', () => {
    const { getByText } = render(
      <ConfirmDialog {...defaultProps} confirmLabel="Yes, delete" cancelLabel="No, keep" />,
    );
    expect(getByText('Yes, delete')).toBeTruthy();
    expect(getByText('No, keep')).toBeTruthy();
  });
});
