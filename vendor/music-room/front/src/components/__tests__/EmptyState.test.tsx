import React from 'react';
import { render } from '@testing-library/react-native';
import { EmptyState } from '../EmptyState';

describe('EmptyState', () => {
  it('renders title', () => {
    const { getByText } = render(<EmptyState title="No events found" />);
    expect(getByText('No events found')).toBeTruthy();
  });

  it('renders description when provided', () => {
    const { getByText } = render(
      <EmptyState title="No events" description="Try adjusting your search filters" />,
    );
    expect(getByText('Try adjusting your search filters')).toBeTruthy();
  });

  it('renders icon when provided', () => {
    const { getByTestId } = render(<EmptyState title="Empty" icon="calendar-blank" />);
    expect(getByTestId('empty-state-icon')).toBeTruthy();
  });

  it('renders action button when provided', () => {
    const { getByText } = render(
      <EmptyState title="No playlists" actionLabel="Create Playlist" onAction={jest.fn()} />,
    );
    expect(getByText('Create Playlist')).toBeTruthy();
  });
});
