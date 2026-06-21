/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   bson.go                                            :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:49:38 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:49:40 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package outboxrelay

// asObject returns v as a map only when it is a JSON object (not an array /
// scalar / nil) — the Go mirror of objectPayload applied to an already-decoded
// value.
func asObject(v any) map[string]any {
	if m, ok := v.(map[string]any); ok {
		return m
	}
	return nil
}

// bsonValue passes JSON-decoded values through. json.Unmarshal already yields
// driver-friendly Go types (map[string]any, []any, float64, string, bool, nil),
// so no conversion is needed; the indirection is a single seam for any future
// type coercion and keeps the builders readable.
func bsonValue(v any) any { return v }
