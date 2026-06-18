package webhooks

import (
	"context"
	"strings"

	redis "github.com/redis/go-redis/v9"
)

// consumeLoop discovers the set of outbox.* streams once per tick and runs
// XREADGROUP against them. Newly-created streams are picked up on the next
// tick.
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

func (d *Dispatcher) ensureGroups(ctx context.Context, streams []string) {
	for _, s := range streams {
		if err := d.ensureGroup(ctx, s); err != nil {
			d.log.Warn("ensure group failed", "stream", s, "err", err)
		}
	}
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
