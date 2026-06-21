/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   ptr_test.go                                        :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:52:52 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:52:53 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package pg

import "testing"

func TestDerefStr(t *testing.T) {
	if got := DerefStr(nil); got != "" {
		t.Fatalf("nil pointer must deref to empty, got %q", got)
	}
	s := "hello"
	if got := DerefStr(&s); got != "hello" {
		t.Fatalf("non-nil must deref to value, got %q", got)
	}
	empty := ""
	if got := DerefStr(&empty); got != "" {
		t.Fatalf("pointer to empty must deref to empty, got %q", got)
	}
}
