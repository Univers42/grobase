/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   dispatcher_streams.go                              :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:44:26 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:44:27 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package functriggers

import (
	"context"
	"strings"
)

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

// ensureGroups creates the consumer group on every discovered stream, logging
// (but not aborting on) per-stream failures — mirrors the original inline loop.
func (d *Dispatcher) ensureGroups(ctx context.Context, streams []string) {
	for _, s := range streams {
		if err := d.ensureGroup(ctx, s); err != nil {
			d.log.Warn("ensure group failed", "stream", s, "err", err)
		}
	}
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
