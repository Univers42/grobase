import React, { useMemo } from 'react';
import { View, StyleSheet, ViewStyle } from 'react-native';
import { Text, useTheme, ProgressBar } from 'react-native-paper';
import { MaterialCommunityIcons } from '@expo/vector-icons';

interface VoteBarProps {
  trackTitle: string;
  artist: string;
  votes: number;
  totalVotes: number;
  hasVoted: boolean;
  rank: number;
  onVote?: () => void;
  style?: ViewStyle;
}

export const VoteBar: React.FC<VoteBarProps> = ({
  trackTitle,
  artist,
  votes,
  totalVotes,
  hasVoted,
  rank,
  onVote,
  style,
}) => {
  const theme = useTheme();
  const percentage = useMemo(
    () => (totalVotes > 0 ? votes / totalVotes : 0),
    [votes, totalVotes],
  );

  const rankColor = useMemo(() => {
    switch (rank) {
      case 1: return '#FFD700';
      case 2: return '#C0C0C0';
      case 3: return '#CD7F32';
      default: return theme.colors.outline;
    }
  }, [rank, theme]);

  return (
    <View
      style={[styles.container, style]}
      accessibilityLabel={`${trackTitle} by ${artist}, ${votes} votes, rank ${rank}`}
    >
      <View style={styles.rankContainer}>
        <Text style={[styles.rank, { color: rankColor }]}>{rank}</Text>
      </View>

      <View style={styles.content}>
        <View style={styles.info}>
          <Text variant="bodyMedium" numberOfLines={1} style={styles.title}>
            {trackTitle}
          </Text>
          <Text
            variant="bodySmall"
            numberOfLines={1}
            style={{ color: theme.colors.onSurfaceVariant }}
          >
            {artist}
          </Text>
        </View>

        <ProgressBar
          progress={percentage}
          color={hasVoted ? theme.colors.primary : theme.colors.surfaceVariant}
          style={styles.progressBar}
        />

        <View style={styles.voteContainer}>
          <MaterialCommunityIcons
            name={hasVoted ? 'thumb-up' : 'thumb-up-outline'}
            size={18}
            color={hasVoted ? theme.colors.primary : theme.colors.outline}
            onPress={onVote}
            accessibilityLabel={hasVoted ? 'Remove vote' : 'Vote for this track'}
            accessibilityRole="button"
          />
          <Text
            variant="labelMedium"
            style={[
              styles.voteCount,
              { color: hasVoted ? theme.colors.primary : theme.colors.onSurfaceVariant },
            ]}
          >
            {votes}
          </Text>
        </View>
      </View>
    </View>
  );
};

const styles = StyleSheet.create({
  container: {
    flexDirection: 'row',
    alignItems: 'center',
    paddingVertical: 8,
    paddingHorizontal: 12,
  },
  rankContainer: {
    width: 28,
    alignItems: 'center',
    marginRight: 10,
  },
  rank: {
    fontSize: 16,
    fontWeight: '700',
  },
  content: {
    flex: 1,
  },
  info: {
    marginBottom: 4,
  },
  title: {
    fontWeight: '500',
  },
  progressBar: {
    height: 4,
    borderRadius: 2,
    marginVertical: 4,
  },
  voteContainer: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 4,
    marginTop: 2,
  },
  voteCount: {
    fontWeight: '600',
  },
});
