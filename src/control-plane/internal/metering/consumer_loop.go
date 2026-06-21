/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   consumer_loop.go                                   :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:47:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:47:02 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package metering

import (
	"context"
	"errors"
	"time"

	redis "github.com/redis/go-redis/v9"
)

// readBatch block-reads the next batch of new entries for the consumer group.
func (c *Consumer) readBatch(ctx context.Context) ([]redis.XStream, error) {
	return c.rdb.XReadGroup(ctx, &redis.XReadGroupArgs{
		Group:    usageGroup,
		Consumer: usageConsumer,
		Streams:  []string{usageStream, ">"},
		Count:    c.batchSize,
		Block:    c.blockWait,
	}).Result()
}

// handleReadErr classifies a readBatch error. It returns true when Run must STOP
// (ctx cancelled). A BLOCK timeout with no new entries (redis.Nil / ctx-cancel
// sentinel) is normal idle — Run loops again; any other error is logged and
// backed off before the next attempt. The bool is "stop", not "retry".
func (c *Consumer) handleReadErr(ctx context.Context, err error) bool {
	if errors.Is(err, redis.Nil) || errors.Is(err, context.Canceled) {
		return false
	}
	if ctx.Err() != nil {
		return true
	}
	c.log.Warn("metering XReadGroup failed", "err", err)
	c.backoff(ctx)
	return false
}

// drain ingests a batch of messages, acking each one it has durably handled. A
// poison entry (errBadEntry) is acked + skipped so a malformed message never
// wedges the group; a transient DB error leaves the message un-acked for
// redelivery (dedup on the idempotency_key makes a redelivered identical window
// a no-op).
func (c *Consumer) drain(ctx context.Context, msgs []redis.XMessage) {
	for _, m := range msgs {
		if err := c.store.Upsert(ctx, m.Values); err != nil {
			if errors.Is(err, errBadEntry) {
				c.log.Warn("metering skipping malformed entry", "id", m.ID)
				_ = c.rdb.XAck(ctx, usageStream, usageGroup, m.ID).Err()
				continue
			}
			c.log.Warn("metering upsert failed — will redeliver", "id", m.ID, "err", err)
			continue
		}
		if err := c.rdb.XAck(ctx, usageStream, usageGroup, m.ID).Err(); err != nil {
			c.log.Warn("metering ack failed", "id", m.ID, "err", err)
		}
	}
}

// backoff sleeps briefly on a Redis error, honoring ctx cancellation.
func (c *Consumer) backoff(ctx context.Context) {
	t := time.NewTimer(time.Second)
	defer t.Stop()
	select {
	case <-ctx.Done():
	case <-t.C:
	}
}

// isBusyGroup reports whether err is the benign "group already exists" reply.
func isBusyGroup(err error) bool {
	return err != nil && len(err.Error()) >= 9 && err.Error()[:9] == "BUSYGROUP"
}
