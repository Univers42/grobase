/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   errors_test.go                                     :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:41:24 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:41:25 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package cmek

import (
	"errors"
	"fmt"
	"testing"
)

// TestErrShredded_ConstParity proves the sentinel survived the var→const-type
// conversion (cmekErr). Its message is the documented literal, %w-wrapping
// preserves errors.Is identity (the property Open relies on when it wraps the
// KMS unwrap failure as `%w: %v`), direct == still holds, and a distinct error
// with the same text does NOT match.
func TestErrShredded_ConstParity(t *testing.T) {
	const wantMsg = "cmek: KMS could not unwrap the DEK (key revoked/deleted or wrong key) — data is crypto-shredded"
	if ErrShredded.Error() != wantMsg {
		t.Errorf("ErrShredded.Error() = %q, want %q", ErrShredded.Error(), wantMsg)
	}

	// The EXACT wrap form Open uses: `fmt.Errorf("%w: %v", ErrShredded, cause)`.
	cause := errors.New("kms: key 'kek-1' is revoked")
	wrapped := fmt.Errorf("%w: %v", ErrShredded, cause)
	if !errors.Is(wrapped, ErrShredded) {
		t.Error("errors.Is(wrapped, ErrShredded) = false, want true (%%w identity lost)")
	}

	// Double-wrap still matches (deep chain).
	if !errors.Is(fmt.Errorf("open mount 9: %w", wrapped), ErrShredded) {
		t.Error("errors.Is through a double-wrap = false, want true")
	}

	// Direct equality via the error interface (const-string comparability).
	var e error = ErrShredded
	if e != ErrShredded {
		t.Error("ErrShredded != ErrShredded via interface — const error not comparable")
	}

	// A distinct error carrying the same text must NOT be ErrShredded.
	if errors.Is(errors.New(wantMsg), ErrShredded) {
		t.Error("a distinct *errorString with the same text must not match ErrShredded")
	}
}
