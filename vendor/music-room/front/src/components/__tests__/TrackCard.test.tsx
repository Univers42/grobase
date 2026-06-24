import React from 'react';
import { render, fireEvent } from '@testing-library/react-native';
import { TrackCard } from '../TrackCard';

const mockTrack = {
  id: '1',
  title: 'Bohemian Rhapsody',
  artist: 'Queen',
  albumCover: 'https://example.com/cover.jpg',
  duration: 354,
  previewUrl: 'https://example.com/preview.mp3',
};

describe('TrackCard', () => {
  it('renders track title and artist', () => {
    const { getByText } = render(<TrackCard track={mockTrack} onPress={jest.fn()} />);
    expect(getByText('Bohemian Rhapsody')).toBeTruthy();
    expect(getByText('Queen')).toBeTruthy();
  });

  it('calls onPress when pressed', () => {
    const onPress = jest.fn();
    const { getByText } = render(<TrackCard track={mockTrack} onPress={onPress} />);
    fireEvent.press(getByText('Bohemian Rhapsody'));
    expect(onPress).toHaveBeenCalledWith(mockTrack);
  });

  it('renders duration in mm:ss format', () => {
    const { getByText } = render(<TrackCard track={mockTrack} onPress={jest.fn()} />);
    expect(getByText('5:54')).toBeTruthy();
  });

  it('renders play button when showPlayButton is true', () => {
    const { getByTestId } = render(
      <TrackCard track={mockTrack} onPress={jest.fn()} showPlayButton />,
    );
    expect(getByTestId('play-button')).toBeTruthy();
  });
});
