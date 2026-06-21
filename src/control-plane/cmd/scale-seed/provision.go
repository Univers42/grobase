/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   provision.go                                       :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:37:07 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:37:08 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"

	"github.com/dlesieur/mini-baas/control-plane/internal/httpx"
)

func buildMountSpecs(dsn, isolation string, mounts int) []mountSpec {
	specs := make([]mountSpec, 0, mounts)
	for m := 0; m < mounts; m++ {
		specs = append(specs, mountSpec{
			Engine:           "postgresql",
			Name:             fmt.Sprintf("bench-m%d", m),
			ConnectionString: dsn,
			Isolation:        isolation,
		})
	}
	return specs
}

// provisionSpec carries the per-tenant provision request parameters
// shared by provisionRequestBody and provisionOne.
type provisionSpec struct {
	slug, plan, dsn, isolation string
	mounts                     int
}

func provisionRequestBody(spec provisionSpec) []byte {
	body, _ := json.Marshal(provisionRequest{
		Tenant:         spec.slug,
		Name:           spec.slug,
		Plan:           spec.plan,
		DefaultKeyName: "scale-bench",
		SeedRoles:      false,
		Mounts:         buildMountSpecs(spec.dsn, spec.isolation, spec.mounts),
	})
	return body
}

func recordFromResources(rec record, out provisionResponse) record {
	for _, r := range out.Resources {
		switch r.Kind {
		case "tenant":
			if r.Status == "created" {
				rec.Status = "created"
			}
		case "mount":
			if r.Status == "error" {
				rec.Status = "error"
				rec.Error = r.Error
			} else if r.ID != "" {
				rec.DBIDs = append(rec.DBIDs, r.ID)
			}
		}
	}
	if out.Outcome == "failed" {
		rec.Status = "error"
		if rec.Error == "" {
			rec.Error = "provision outcome: failed"
		}
	}
	return rec
}

func parseProvision(slug string, out provisionResponse) record {
	rec := record{Slug: slug, Status: "exists"}
	if out.APIKey != nil {
		rec.Key = out.APIKey.Key
		rec.KeyID = out.APIKey.ID
	}
	return recordFromResources(rec, out)
}

func provisionOne(client *http.Client, base, token string, spec provisionSpec) record {
	body := provisionRequestBody(spec)
	req, err := http.NewRequest(http.MethodPost, base+"/v1/provision", bytes.NewReader(body))
	if err != nil {
		return record{Slug: spec.slug, Status: "error", Error: err.Error()}
	}
	req.Header.Set("Content-Type", "application/json")
	serviceHeaders(req, token, string(body))
	resp, err := client.Do(req)
	if err != nil {
		return record{Slug: spec.slug, Status: "error", Error: err.Error()}
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if resp.StatusCode != http.StatusOK && resp.StatusCode != http.StatusCreated {
		return record{
			Slug: spec.slug, Status: "error",
			Error: fmt.Sprintf("provision %d: %s", resp.StatusCode, httpx.RedactDSN(string(raw))),
		}
	}
	var out provisionResponse
	if err := json.Unmarshal(raw, &out); err != nil {
		return record{Slug: spec.slug, Status: "error", Error: "bad provision response: " + err.Error()}
	}
	return parseProvision(spec.slug, out)
}
