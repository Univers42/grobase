package ipguard

import (
	"context"
	"net"
	"strings"

	"github.com/jackc/pgx/v5"
)

// queryRow runs a single-row query via AdminQuery and adapts it to a pgx.Row.
func (s *Service) queryRow(ctx context.Context, sql string, args ...any) pgx.Row {
	return rowQuery{s.db, ctx, sql, args}
}

type rowQuery struct {
	db   idb
	ctx  context.Context
	sql  string
	args []any
}

func (q rowQuery) Scan(dest ...any) error {
	rows, err := q.db.AdminQuery(q.ctx, q.sql, q.args...)
	if err != nil {
		return err
	}
	defer rows.Close()
	if !rows.Next() {
		if err := rows.Err(); err != nil {
			return err
		}
		return pgx.ErrNoRows
	}
	return rows.Scan(dest...)
}

// normalizeCIDR turns a user-supplied value into a canonical CIDR string. A bare
// host becomes /32 (IPv4) or /128 (IPv6); a CIDR is re-emitted in canonical form
// (network address + mask). A value that is neither is ErrBadCIDR.
func normalizeCIDR(raw string) (string, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return "", ErrBadCIDR
	}
	if strings.Contains(raw, "/") {
		_, network, err := net.ParseCIDR(raw)
		if err != nil || network == nil {
			return "", ErrBadCIDR
		}
		return network.String(), nil
	}
	ip := parseIP(raw)
	if ip == nil {
		return "", ErrBadCIDR
	}
	if ip.To4() != nil {
		return ip.String() + "/32", nil
	}
	return ip.String() + "/128", nil
}

// parseIP parses a single IP, tolerating an IPv6 zone and surrounding brackets.
func parseIP(raw string) net.IP {
	raw = strings.TrimSpace(raw)
	raw = strings.TrimPrefix(strings.TrimSuffix(raw, "]"), "[")
	if i := strings.IndexByte(raw, '%'); i >= 0 { // strip IPv6 zone (fe80::1%eth0)
		raw = raw[:i]
	}
	return net.ParseIP(raw)
}
