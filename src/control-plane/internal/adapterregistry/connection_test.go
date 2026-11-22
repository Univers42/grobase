/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   connection_test.go                                 :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/11/22 01:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/11/22 01:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package adapterregistry

import (
	"os"
	"strings"
	"testing"
)

// TestLoadMountRowDoesNotStampHealth verifies that loading a mount definition
// never executes an UPDATE on last_healthy_at (grobase#103). Health observation
// belongs exclusively to live engine probes/connections, avoiding false-positive
// health timestamps for unreachable backends.
func TestLoadMountRowDoesNotStampHealth(t *testing.T) {
	content, err := os.ReadFile("connection.go")
	if err != nil {
		t.Fatalf("failed to read connection.go: %v", err)
	}
	src := string(content)

	idx := strings.Index(src, "func (s *Service) loadMountRow")
	if idx == -1 {
		t.Fatalf("loadMountRow function not found in connection.go")
	}
	endIdx := strings.Index(src[idx:], "func scanMountRow")
	if endIdx == -1 {
		t.Fatalf("scanMountRow function not found after loadMountRow in connection.go")
	}
	fnBody := src[idx : idx+endIdx]

	if strings.Contains(strings.ToUpper(fnBody), "UPDATE") {
		t.Fatalf("loadMountRow must not execute UPDATE: %s", fnBody)
	}
	if strings.Contains(fnBody, "last_healthy_at") {
		t.Fatalf("loadMountRow must not reference last_healthy_at: %s", fnBody)
	}
}
