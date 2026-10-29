/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   descriptor_dsn.go                                  :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/10/29 20:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/10/29 20:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package adapterregistry

import (
	"net/netip"
	"net/url"
	"path"
	"strconv"
	"strings"
)

// Caveat: TLS is what the DSN REQUESTS, read from a fixed key list (sslmode, ssl-mode, tls,
// ssl, encrypt, tlsInsecure, trustServerCertificate, rediss://, https://, #insecure); a
// driver default or a server that downgrades is reported as "default", not as what was
// negotiated (that is the data plane's to say, G4b). The platform test is a heuristic: a
// dot-less name, loopback, RFC 1918, CGNAT or a .internal/.local suffix is hidden as
// "platform" even when it is the tenant's own LAN box (over-hiding, never over-showing),
// and a public name that resolves to a private address is shown.

const (
	locationNetwork  = "network"
	locationPlatform = "platform"
	locationFile     = "file"
	locationMemory   = "memory"
	locationUnknown  = "unknown"
	tlsUnknown       = "unknown"
)

type dsnFacts struct {
	location, host, file, database, tls string
	port                                int
}

// describeDSN reduces a DSN to the facts the UI may show. Every returned string is then
// checked against the DSN's password, so a password that also appears as a host, path or
// database name is dropped rather than echoed.
func describeDSN(engine, dsn string) dsnFacts {
	var f dsnFacts
	var secret string
	switch engine {
	case "sqlite":
		f = describeSQLite(dsn)
	case "mssql":
		f, secret = describeMSSQL(dsn)
	default:
		f, secret = describeURL(engine, dsn)
	}
	return f.scrub(secret)
}

func describeSQLite(dsn string) dsnFacts {
	p := strings.TrimPrefix(strings.TrimPrefix(dsn, "sqlite://"), "sqlite:")
	if p == "" || p == ":memory:" {
		return dsnFacts{location: locationMemory, tls: "n/a"}
	}
	p, _, _ = strings.Cut(p, "?")
	return dsnFacts{location: locationFile, file: path.Base(p), tls: "n/a"}
}

// describeMSSQL mirrors the data plane's split (rewriteMSSQL): credentials end at the first
// '@', no percent-decoding.
func describeMSSQL(dsn string) (dsnFacts, string) {
	_, rest, ok := strings.Cut(dsn, "://")
	creds, hostpart, found := strings.Cut(rest, "@")
	// A second '@' means the password held one: the host side would start with its tail.
	if !ok || !found || strings.Contains(hostpart, "@") {
		return dsnFacts{location: locationUnknown, tls: tlsUnknown}, ""
	}
	_, secret, _ := strings.Cut(creds, ":")
	hostpart, query, _ := strings.Cut(hostpart, "?")
	hostPort, db, _ := strings.Cut(hostpart, "/")
	host, portText, _ := strings.Cut(hostPort, ":")
	values, _ := url.ParseQuery(query)
	f := placeHost(host, portText)
	f.database = db
	f.tls = tlsFromQuery(values, "")
	return f, secret
}

func describeURL(engine, dsn string) (dsnFacts, string) {
	u, err := url.Parse(dsn)
	if err != nil || u.Host == "" {
		return dsnFacts{location: locationUnknown, tls: tlsUnknown}, ""
	}
	secret, _ := u.User.Password()
	host, portText := splitFirstHost(u.Host)
	f := placeHost(host, portText)
	if engine != "http" && engine != "dynamodb" {
		f.database = strings.TrimPrefix(u.Path, "/")
	}
	f.tls = tlsFromQuery(u.Query(), u.Scheme)
	if u.Fragment == "insecure" {
		f.tls = "insecure"
	}
	return f, secret
}

// splitFirstHost takes the first member of a mongo seed list (h1:27017,h2:27017).
func splitFirstHost(hosts string) (string, string) {
	first, _, _ := strings.Cut(hosts, ",")
	u := url.URL{Host: first}
	return u.Hostname(), u.Port()
}

func placeHost(host, portText string) dsnFacts {
	if host == "" {
		return dsnFacts{location: locationUnknown}
	}
	if isPlatformHost(host) {
		return dsnFacts{location: locationPlatform}
	}
	port, _ := strconv.Atoi(portText)
	return dsnFacts{location: locationNetwork, host: host, port: port}
}

func isPlatformHost(host string) bool {
	lower := strings.ToLower(strings.TrimSuffix(host, "."))
	if lower == "localhost" || strings.HasSuffix(lower, ".internal") || strings.HasSuffix(lower, ".local") {
		return true
	}
	addr, err := netip.ParseAddr(strings.Trim(lower, "[]"))
	if err != nil {
		return !strings.Contains(lower, ".")
	}
	return addr.IsLoopback() || addr.IsPrivate() || addr.IsLinkLocalUnicast() || addr.IsUnspecified() ||
		netip.MustParsePrefix("100.64.0.0/10").Contains(addr)
}

// tlsFromQuery maps the requested posture onto a closed set, so no query value is echoed.
func tlsFromQuery(q url.Values, scheme string) string {
	for _, key := range []string{"tlsInsecure", "trustServerCertificate", "tlsAllowInvalidCertificates"} {
		if strings.EqualFold(q.Get(key), "true") {
			return "insecure"
		}
	}
	for _, key := range []string{"sslmode", "ssl-mode", "tls", "ssl", "encrypt"} {
		switch strings.ToLower(q.Get(key)) {
		case "verify-full", "verify-ca", "verify_identity", "verify_ca", "strict":
			return "verify"
		case "require", "required", "true", "preferred", "prefer":
			return "on"
		case "disable", "disabled", "false", "allow":
			return "off"
		}
	}
	switch scheme {
	case "rediss", "https", "mongodb+srv":
		return "on"
	case "redis", "http":
		return "off"
	}
	return "default"
}

func (f dsnFacts) scrub(secret string) dsnFacts {
	if secret == "" {
		return f
	}
	leaks := func(s string) bool { return s != "" && strings.Contains(s, secret) }
	if leaks(f.host) {
		f.host, f.port, f.location = "", 0, locationUnknown
	}
	if leaks(f.file) {
		f.file = ""
	}
	if leaks(f.database) {
		f.database = ""
	}
	return f
}
