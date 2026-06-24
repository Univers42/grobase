/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   quotastage_test.go                                 :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:54:34 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:54:35 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package quotastage

import "testing"

// TestParseStage: the default (empty / garbage) is OFF — a typo can NEVER promote
// to enforce. Each known stage parses to itself (case-insensitive).
func TestParseStage(t *testing.T) {
	cases := map[string]Stage{
		"":        StageOff,
		"off":     StageOff,
		"garbage": StageOff, // unrecognized → off (fail toward parity)
		"shadow":  StageShadow,
		"SHADOW":  StageShadow,
		" warn ":  StageWarn,
		"enforce": StageEnforce,
		"Enforce": StageEnforce,
	}
	for in, want := range cases {
		if got := ParseStage(in); got != want {
			t.Errorf("ParseStage(%q) = %q, want %q", in, got, want)
		}
	}
}

// TestDecide is the promotion ladder. The transition assertion: the SAME over-quota
// tenant gets Allow→ShadowLog→WarnHeader→Block as the stage is promoted, and an
// under-quota tenant is ALWAYS Allow regardless of stage (no false positives).
func TestDecide(t *testing.T) {
	// Under quota → always Allow.
	for _, s := range []Stage{StageOff, StageShadow, StageWarn, StageEnforce} {
		if got := Decide(false, s); got != ActionAllow {
			t.Errorf("Decide(under, %q) = %v, want Allow", s, got)
		}
	}
	// Over quota → escalates with the stage.
	overWant := map[Stage]Action{
		StageOff:     ActionAllow,     // parity: set ignored, exactly today
		StageShadow:  ActionShadowLog, // serve 200, log would-be-block
		StageWarn:    ActionWarnHeader,
		StageEnforce: ActionBlock, // the real B2 402
	}
	for s, want := range overWant {
		if got := Decide(true, s); got != want {
			t.Errorf("Decide(over, %q) = %v, want %v", s, got, want)
		}
	}
}

// TestBlocksOnlyEnforce: only enforce hard-blocks (off/shadow/warn never 402).
func TestBlocksOnlyEnforce(t *testing.T) {
	if Blocks(StageOff) || Blocks(StageShadow) || Blocks(StageWarn) {
		t.Fatal("only enforce should block")
	}
	if !Blocks(StageEnforce) {
		t.Fatal("enforce must block")
	}
}
