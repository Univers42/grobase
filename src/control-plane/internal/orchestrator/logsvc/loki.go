/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   loki.go                                            :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:49:06 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:49:08 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package logsvc

import (
	"encoding/json"
	"strconv"
	"time"
)

// toLokiStream mirrors the Node `toLokiStream`: one stream per entry, labelled
// by service+level, with the full record (plus request_id promotion) as the line.
func toLokiStream(e Entry) map[string]any {
	t, err := time.Parse(time.RFC3339Nano, e.CreatedAt)
	if err != nil {
		t = time.Now()
	}
	line := map[string]any{
		"service": e.Source,
		"level":   e.Level,
		"message": e.Message,
	}
	for k, v := range e.Data {
		line[k] = v
	}
	if rid, ok := e.Data["request_id"]; ok {
		line["request_id"] = rid
	}
	lineJSON, _ := json.Marshal(line)
	return map[string]any{
		"stream": map[string]any{"service": e.Source, "level": e.Level},
		"values": [][2]string{{strconv.FormatInt(t.UnixNano(), 10), string(lineJSON)}},
	}
}

func orDefault(v, def string) string {
	if v == "" {
		return def
	}
	return v
}
