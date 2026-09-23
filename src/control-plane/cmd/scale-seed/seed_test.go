/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   seed_test.go                                       :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/09/23 23:50:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/09/23 23:50:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package main

import (
	"bufio"
	"os"
	"path/filepath"
	"testing"
)

const sinkRecord = "{\"slug\":\"scale-000001\",\"status\":\"error\"}\n"

// TestCloseSinkPersistsRecords proves a healthy sink is flushed and closed with
// no error, so every buffered JSONL record reaches the out file.
func TestCloseSinkPersistsRecords(t *testing.T) {
	path := filepath.Join(t.TempDir(), "tenants.jsonl")
	sink, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	w := bufio.NewWriter(sink)
	_, _ = w.WriteString(sinkRecord)
	if err := closeSink(w, sink); err != nil {
		t.Fatalf("closeSink on a healthy sink: %v", err)
	}
	got, err := os.ReadFile(path)
	if err != nil || string(got) != sinkRecord {
		t.Fatalf("out file = %q (err %v), want %q", got, err, sinkRecord)
	}
}

// TestCloseSinkSurfacesLostRecords proves a flush that cannot reach the file is
// returned, never dropped: with the fd already closed under the buffered writer
// the record is lost, and closeSink must say so.
func TestCloseSinkSurfacesLostRecords(t *testing.T) {
	sink, err := os.Create(filepath.Join(t.TempDir(), "tenants.jsonl"))
	if err != nil {
		t.Fatal(err)
	}
	w := bufio.NewWriter(sink)
	_, _ = w.WriteString(sinkRecord)
	_ = sink.Close()
	if err := closeSink(w, sink); err == nil {
		t.Fatal("closeSink returned nil although the buffered record was never written")
	}
}
