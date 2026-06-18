import React from 'react';
import { View, StyleSheet, FlatList, RefreshControl } from 'react-native';
import { ActivityIndicator, Text, Button, useTheme } from 'react-native-paper';

interface InfiniteListProps<T> {
  data: T[];
  renderItem: ({ item, index }: { item: T; index: number }) => React.ReactElement;
  keyExtractor: (item: T, index: number) => string;
  onLoadMore?: () => void;
  onRefresh?: () => void;
  hasMore?: boolean;
  loading?: boolean;
  refreshing?: boolean;
  error?: string | null;
  onRetry?: () => void;
  emptyMessage?: string;
  emptyIcon?: string;
  ListHeaderComponent?: React.ReactElement;
  contentContainerStyle?: object;
}

export function InfiniteList<T>({
  data,
  renderItem,
  keyExtractor,
  onLoadMore,
  onRefresh,
  hasMore,
  loading,
  refreshing,
  error,
  onRetry,
  emptyMessage = 'No items found',
  ListHeaderComponent,
  contentContainerStyle,
}: InfiniteListProps<T>) {
  const theme = useTheme();

  const renderFooter = () => {
    if (error) {
      return (
        <View style={styles.footer}>
          <Text variant="bodySmall" style={{ color: theme.colors.error }}>
            {error}
          </Text>
          {onRetry && (
            <Button mode="text" onPress={onRetry} compact>
              Retry
            </Button>
          )}
        </View>
      );
    }

    if (loading && data.length > 0) {
      return (
        <View style={styles.footer}>
          <ActivityIndicator size="small" />
        </View>
      );
    }

    if (!hasMore && data.length > 0) {
      return (
        <View style={styles.footer}>
          <Text variant="bodySmall" style={{ color: theme.colors.onSurfaceVariant }}>
            No more items
          </Text>
        </View>
      );
    }

    return null;
  };

  const renderEmpty = () => {
    if (loading) {
      return (
        <View style={styles.emptyContainer}>
          <ActivityIndicator size="large" />
        </View>
      );
    }

    return (
      <View style={styles.emptyContainer}>
        <Text variant="bodyLarge" style={{ color: theme.colors.onSurfaceVariant }}>
          {emptyMessage}
        </Text>
      </View>
    );
  };

  return (
    <FlatList
      data={data}
      renderItem={renderItem}
      keyExtractor={keyExtractor}
      onEndReached={hasMore && !loading ? onLoadMore : undefined}
      onEndReachedThreshold={0.3}
      ListFooterComponent={renderFooter}
      ListEmptyComponent={renderEmpty}
      ListHeaderComponent={ListHeaderComponent}
      refreshControl={
        onRefresh ? (
          <RefreshControl refreshing={refreshing || false} onRefresh={onRefresh} />
        ) : undefined
      }
      contentContainerStyle={[
        data.length === 0 && styles.emptyList,
        contentContainerStyle,
      ]}
    />
  );
}

const styles = StyleSheet.create({
  footer: {
    padding: 16,
    alignItems: 'center',
  },
  emptyContainer: {
    flex: 1,
    justifyContent: 'center',
    alignItems: 'center',
    padding: 32,
  },
  emptyList: {
    flexGrow: 1,
  },
});
