package webhooks

import (
	"context"
	"errors"
	"strings"
	"time"

	redis "github.com/redis/go-redis/v9"
)

func (d *Dispatcher) readStreams(ctx context.Context, streams []string) ([]redis.XStream, error) {
	args := make([]string, 0, len(streams)*2)
	args = append(args, streams...)
	for range streams {
		args = append(args, ">")
	}
	return d.rdb.XReadGroup(ctx, &redis.XReadGroupArgs{
		Group:    d.groupName,
		Consumer: d.consumer,
		Streams:  args,
		Count:    32,
		Block:    2 * time.Second,
	}).Result()
}

func isTransientReadErr(err error) bool {
	return errors.Is(err, redis.Nil) ||
		errors.Is(err, context.Canceled) ||
		errors.Is(err, context.DeadlineExceeded)
}

// discoverStreams scans Redis keyspace for outbox.* streams.
func (d *Dispatcher) discoverStreams(ctx context.Context) ([]string, error) {
	var (
		cursor uint64
		out    []string
	)
	for {
		keys, next, err := d.rdb.Scan(ctx, cursor, "outbox.*", 256).Result()
		if err != nil {
			return nil, err
		}
		for _, k := range keys {
			t, err := d.rdb.Type(ctx, k).Result()
			if err == nil && t == "stream" {
				out = append(out, k)
			}
		}
		if next == 0 {
			break
		}
		cursor = next
	}
	return out, nil
}

func (d *Dispatcher) ensureGroup(ctx context.Context, stream string) error {
	err := d.rdb.XGroupCreateMkStream(ctx, stream, d.groupName, "0").Err()
	if err == nil {
		return nil
	}
	if strings.Contains(err.Error(), "BUSYGROUP") {
		return nil
	}
	return err
}
