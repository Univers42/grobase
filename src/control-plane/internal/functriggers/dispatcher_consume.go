/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   dispatcher_consume.go                              :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:44:17 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:44:18 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package functriggers

import (
	"context"
	"errors"
	"strings"
	"time"

	redis "github.com/redis/go-redis/v9"
)

func (d *Dispatcher) consumeLoop(ctx context.Context) error {
	for {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		d.consumeTick(ctx)
	}
}

func (d *Dispatcher) consumeTick(ctx context.Context) {
	streams, err := d.discoverStreams(ctx)
	if err != nil {
		d.log.Warn("stream discovery failed", "err", err)
		d.sleep(ctx, d.pollPause)
		return
	}
	if len(streams) == 0 {
		d.sleep(ctx, d.pollPause)
		return
	}
	d.ensureGroups(ctx, streams)
	res, err := d.readStreams(ctx, streams)
	if err != nil {
		if !isTransientReadErr(err) {
			d.log.Warn("xreadgroup failed", "err", err)
			d.sleep(ctx, d.pollPause)
		}
		return
	}
	for _, st := range res {
		d.processStream(ctx, st)
	}
}

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

func (d *Dispatcher) processStream(ctx context.Context, st redis.XStream) {
	aggregate := strings.TrimPrefix(st.Stream, "outbox.")
	for _, msg := range st.Messages {
		if err := d.handleEvent(ctx, aggregate, msg); err != nil {
			d.log.Warn("handle event failed", "stream", st.Stream, "id", msg.ID, "err", err)
			continue
		}
		if err := d.rdb.XAck(ctx, st.Stream, d.groupName, msg.ID).Err(); err != nil {
			d.log.Warn("xack failed", "stream", st.Stream, "id", msg.ID, "err", err)
		}
	}
}

func isTransientReadErr(err error) bool {
	return errors.Is(err, redis.Nil) ||
		errors.Is(err, context.Canceled) ||
		errors.Is(err, context.DeadlineExceeded)
}
