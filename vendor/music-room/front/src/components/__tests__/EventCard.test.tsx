import React from 'react';
import { render, fireEvent } from '@testing-library/react-native';
import { EventCard } from '../EventCard';

const mockEvent = {
  id: '1',
  name: 'Summer Jam',
  description: 'Music festival in the park',
  date: '2024-07-15T18:00:00.000Z',
  location: { name: 'Central Park', coordinates: [2.35, 48.86] },
  participantCount: 42,
  maxParticipants: 100,
  visibility: 'public' as const,
  owner: { username: 'john_doe', avatarUrl: '' },
};

describe('EventCard', () => {
  it('renders event name', () => {
    const { getByText } = render(<EventCard event={mockEvent} onPress={jest.fn()} />);
    expect(getByText('Summer Jam')).toBeTruthy();
  });

  it('renders location name', () => {
    const { getByText } = render(<EventCard event={mockEvent} onPress={jest.fn()} />);
    expect(getByText('Central Park')).toBeTruthy();
  });

  it('renders participant count', () => {
    const { getByText } = render(<EventCard event={mockEvent} onPress={jest.fn()} />);
    expect(getByText('42/100')).toBeTruthy();
  });

  it('calls onPress when card is pressed', () => {
    const onPress = jest.fn();
    const { getByText } = render(<EventCard event={mockEvent} onPress={onPress} />);
    fireEvent.press(getByText('Summer Jam'));
    expect(onPress).toHaveBeenCalledWith(mockEvent);
  });

  it('shows private badge for private events', () => {
    const privateEvent = { ...mockEvent, visibility: 'private' as const };
    const { getByText } = render(<EventCard event={privateEvent} onPress={jest.fn()} />);
    expect(getByText('Private')).toBeTruthy();
  });
});
