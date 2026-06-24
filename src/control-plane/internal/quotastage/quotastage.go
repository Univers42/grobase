/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   quotastage.go                                      :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:54:37 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:54:38 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

// Package quotastage (Track-B B7.2) is the STAGED metering→quota promotion knob.
// It lets an operator promote quota enforcement GRADUALLY rather than flipping a
// public free tier from "never blocked" to "402 on the next request" in one step:
//
//	off     → exactly today. No would-be-block is computed, no header, no 402.
//	          (the byte-parity baseline; the B2 QuotaGuard's enforcement effect is
//	          unchanged whether or not the guard is publishing the over-quota set.)
//	shadow  → compute the would-be-block, LOG it, but SERVE the request (200).
//	          Operators watch the shadow logs to size the blast radius before enforce.
//	warn    → serve the request (200) but add an advisory header
//	          (X-Quota-Status: over) so a client sees the warning before it bites.
//	enforce → the real B2 behavior: an over-quota request is rejected (402).
//
// It WRAPS the existing B2 quota guard — it does NOT replace it. The over-quota
// DECISION (which tenant is over its tier cap) still comes from
// metering.QuotaGuard publishing the `quota:over` Redis set; quotastage only maps
// (is-over, stage) → an action {Allow, Header, Block}. The data plane reads
// QUOTA_STAGE the same cheap way it reads the over-quota snapshot (a process-env at
// boot / a refreshed value), so there is NO per-request DB or Redis cost added by
// staging.
//
// FLAG-DEFAULT off = PARITY: QUOTA_STAGE defaults to "off", which is identical to
// the pre-B7.2 world — Decide always returns Allow with no header and no block,
// regardless of the over-quota set. Promotion is an explicit, reversible operator
// action (off→shadow→warn→enforce, and back). An unrecognized stage value degrades
// to "off" (fail toward parity), never to enforce.
package quotastage

import (
	"os"
	"strings"
)

// Stage is the promotion level for quota enforcement.
type Stage string

const (
	// StageOff is the parity default: no would-be-block, no header, no 402.
	StageOff Stage = "off"
	// StageShadow computes the would-be-block and logs it, but serves (200).
	StageShadow Stage = "shadow"
	// StageWarn serves (200) but adds an advisory X-Quota-Status header.
	StageWarn Stage = "warn"
	// StageEnforce is the real B2 behavior: over-quota → 402.
	StageEnforce Stage = "enforce"
)

// Action is what the caller should DO for one request, given (is-over, stage).
type Action int

const (
	// ActionAllow: serve normally (no header). The only action for an UNDER-quota
	// request, and the action for an over-quota request in off/shadow stage.
	ActionAllow Action = iota
	// ActionShadowLog: serve normally, but the caller should LOG a would-be-block
	// (shadow stage, over quota). Distinct from Allow so the shadow signal is
	// observable without changing the response.
	ActionShadowLog
	// ActionWarnHeader: serve normally, add the advisory X-Quota-Status header
	// (warn stage, over quota).
	ActionWarnHeader
	// ActionBlock: reject with 402 (enforce stage, over quota).
	ActionBlock
)

// WarnHeaderName / WarnHeaderValue are the advisory header the data plane stamps in
// warn stage (RFC-ish, mirrors the Deprecation/Sunset convention B7.11 will use).
const (
	WarnHeaderName  = "X-Quota-Status"
	WarnHeaderValue = "over"
)

// ParseStage maps a string to a Stage, defaulting to StageOff (parity) for empty
// or unrecognized input — a typo can NEVER silently promote to enforce.
func ParseStage(s string) Stage {
	switch strings.ToLower(strings.TrimSpace(s)) {
	case string(StageShadow):
		return StageShadow
	case string(StageWarn):
		return StageWarn
	case string(StageEnforce):
		return StageEnforce
	default:
		return StageOff
	}
}

// FromEnv reads QUOTA_STAGE (default "off"). One source of truth for the stage.
func FromEnv() Stage { return ParseStage(os.Getenv("QUOTA_STAGE")) }

// Decide maps (isOver, stage) → the action the caller should take. isOver is the
// existing B2 over-quota decision (tenant ∈ quota:over). The whole function is the
// promotion ladder in one place:
//
//	UNDER quota          → Allow (every stage)
//	OVER quota, off      → Allow         (parity — set ignored, exactly today)
//	OVER quota, shadow   → ShadowLog     (serve 200, log the would-be-block)
//	OVER quota, warn     → WarnHeader    (serve 200, advisory header)
//	OVER quota, enforce  → Block         (402)
func Decide(isOver bool, stage Stage) Action {
	if !isOver {
		return ActionAllow
	}
	switch stage {
	case StageShadow:
		return ActionShadowLog
	case StageWarn:
		return ActionWarnHeader
	case StageEnforce:
		return ActionBlock
	default:
		return ActionAllow
	}
}

// Blocks reports whether a stage would 402 an over-quota request (i.e. enforce).
// Convenience for a caller that only needs the hard-block bit.
func Blocks(stage Stage) bool { return stage == StageEnforce }
