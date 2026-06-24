/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   main.go                                            :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:37:05 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:37:06 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

// scale-seed — bulk tenant provisioner for the 10K-tenant scale experiments
// (program phase B1). Drives tenant-control's idempotent POST /v1/provision
// with bounded concurrency, capturing each tenant's api key + mount ids as
// JSONL so the k6 multi-tenant workload (B2) and m39 can replay them.
//
//	go run ./cmd/scale-seed -n 10000 -base http://127.0.0.1:<tc-port> \
//	    -dsn postgres://user:pass@postgres:5432/db -out artifacts/scale/tenants-10000.jsonl
//	go run ./cmd/scale-seed -teardown -out artifacts/scale/tenants-10000.jsonl
//
// Deterministic slugs (scale-000001…), idempotent (re-runs reuse the existing
// key via provision's key_reuse), resumable (-resume skips slugs already in
// the out file). Concurrency is deliberately modest by default: every first
// provision mints an Argon2id key hash (~50ms CPU) on tenant-control.
package main

import (
	"fmt"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/dlesieur/mini-baas/control-plane/internal/serviceauth"
)

type mountSpec struct {
	Engine           string `json:"engine"`
	Name             string `json:"name"`
	ConnectionString string `json:"connection_string"`
	Isolation        string `json:"isolation"`
}

type provisionRequest struct {
	Tenant         string      `json:"tenant"`
	Name           string      `json:"name"`
	Plan           string      `json:"plan"`
	DefaultKeyName string      `json:"default_key_name"`
	SeedRoles      bool        `json:"seed_roles"`
	Mounts         []mountSpec `json:"mounts"`
}

// The live /v1/provision returns a reconcile result: tenant + api_key +
// outcome + a flat resources[] (one per tenant/key/mount/role step). See
// internal/provision/reconcile.go (ReconcileResult / ResourceResult).
type provisionResponse struct {
	APIKey *struct {
		ID  string `json:"id"`
		Key string `json:"key"`
	} `json:"api_key"`
	Outcome   string `json:"outcome"` // complete | partial | failed
	Resources []struct {
		Kind   string `json:"kind"`   // tenant | key | mount | role | …
		Status string `json:"status"` // created | exists | error
		ID     string `json:"id"`
		Error  string `json:"error"`
	} `json:"resources"`
}

// One JSONL record per tenant — the contract B2/m39 read.
type record struct {
	Slug   string   `json:"slug"`
	Key    string   `json:"key,omitempty"`
	KeyID  string   `json:"key_id,omitempty"`
	DBIDs  []string `json:"db_ids"`
	Status string   `json:"status"` // created | exists | error
	Error  string   `json:"error,omitempty"`
}

func serviceHeaders(req *http.Request, token, body string) {
	if strings.EqualFold(os.Getenv("SERVICE_TOKEN_MODE"), "hmac") {
		req.Header.Set("X-Service-Auth",
			serviceauth.ComputeServiceSignature(token, serviceauth.SignedRequest{
				Method: req.Method, Path: req.URL.Path, Body: []byte(body), TS: time.Now().Unix(),
			}))
	} else {
		req.Header.Set("X-Service-Token", token)
	}
}

func main() {
	cfg := parseFlags()
	client := &http.Client{Timeout: 30 * time.Second}
	if *cfg.token == "" {
		fmt.Fprintln(os.Stderr, "missing -token / INTERNAL_SERVICE_TOKEN")
		os.Exit(2)
	}
	if *cfg.doTeardown {
		if err := teardown(client, *cfg.base, *cfg.token, *cfg.out); err != nil {
			fmt.Fprintln(os.Stderr, "teardown:", err)
			os.Exit(1)
		}
		return
	}
	if *cfg.dsn == "" {
		fmt.Fprintln(os.Stderr, "missing -dsn / SCALE_MOUNT_DSN")
		os.Exit(2)
	}
	if err := seed(client, cfg); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
