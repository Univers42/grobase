/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   ssrf.go                                            :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:54:26 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:54:27 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package push

import (
	"fmt"
	"net"
	"net/url"
	"os"
	"strings"
)

// guardTarget is the SSRF wall (mirrors the intent of webhooks' outbound guard).
// It rejects a target_url that is not a public http(s) endpoint:
//   - a non-http(s) scheme,
//   - a host that IS a literal private/loopback/link-local/unspecified IP, or
//   - a hostname EVERY resolved A/AAAA record of which is private/loopback/
//     link-local/unspecified (a hostname that resolves to a public IP is allowed;
//     one that resolves only to internal space — e.g. an internal DNS name or a
//     rebinding name — is refused).
//
// Refusing on resolution failure is intentional fail-closed: a name we cannot
// resolve is not a proven-public destination.
//
// A narrow operator allowlist (PUSH_SSRF_ALLOW_HOSTS, comma-separated host
// entries; default empty) is consulted first and permits naming specific
// internal webhook targets for in-cluster delivery. Default empty => nothing
// private is allowed => the rest of the guard applies unchanged (production stays
// SSRF-locked = byte-parity). A literal-IP host is then checked directly; a
// hostname is resolved and validated.
func guardTarget(raw string) error {
	u, err := url.Parse(raw)
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") {
		return fmt.Errorf("%w: scheme must be http(s)", ErrBlockedTarget)
	}
	host := u.Hostname()
	if host == "" {
		return fmt.Errorf("%w: empty host", ErrBlockedTarget)
	}
	if hostAllowlisted(host) {
		return nil
	}
	if ip := net.ParseIP(host); ip != nil {
		if isBlockedIP(ip) {
			return fmt.Errorf("%w: %s is a private/loopback/link-local address", ErrBlockedTarget, host)
		}
		return nil
	}
	return guardResolvedHost(host)
}

// guardResolvedHost resolves a hostname and requires at least one public IP,
// rejecting if ANY resolved address is internal (a name resolving to a mix is
// suspicious — fail closed on the safe side).
func guardResolvedHost(host string) error {
	ips, err := net.LookupIP(host)
	if err != nil || len(ips) == 0 {
		return fmt.Errorf("%w: cannot resolve %q to a public address", ErrBlockedTarget, host)
	}
	for _, ip := range ips {
		if isBlockedIP(ip) {
			return fmt.Errorf("%w: %s resolves to internal address %s", ErrBlockedTarget, host, ip)
		}
	}
	return nil
}

// hostAllowlisted reports whether host is named in PUSH_SSRF_ALLOW_HOSTS — a
// comma-separated allowlist of hostnames/IPs the operator explicitly trusts for
// in-cluster delivery. Default empty => always false => the SSRF guard applies
// unchanged (byte-parity). This is the deliberate, opt-in operator escape hatch
// for delivering to a known private endpoint without weakening the guard for any
// other target; only an exact (case-insensitive) host match is trusted.
func hostAllowlisted(host string) bool {
	raw := strings.TrimSpace(os.Getenv("PUSH_SSRF_ALLOW_HOSTS"))
	if raw == "" {
		return false
	}
	for _, entry := range strings.Split(raw, ",") {
		if e := strings.TrimSpace(entry); e != "" && strings.EqualFold(e, host) {
			return true
		}
	}
	return false
}

// isBlockedIP reports whether ip is in a range we must never POST to from the
// control plane: loopback, link-local (incl. 169.254.0.0/16 — the cloud
// metadata range), private RFC1918/ULA, unspecified, and — via extraBlockedV4,
// the additional reserved IPv4 ranges the net.IP helpers do not cover — the
// carrier-grade-NAT / benchmarking / documentation ranges that should never be
// a legitimate public push endpoint.
func isBlockedIP(ip net.IP) bool {
	if ip.IsLoopback() || ip.IsLinkLocalUnicast() || ip.IsLinkLocalMulticast() ||
		ip.IsPrivate() || ip.IsUnspecified() || ip.IsMulticast() {
		return true
	}
	for _, cidr := range extraBlockedV4() {
		if cidr.Contains(ip) {
			return true
		}
	}
	return false
}
