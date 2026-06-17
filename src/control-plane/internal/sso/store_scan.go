package sso

import "github.com/jackc/pgx/v5"

// scanOne reads exactly one row (ErrConnectionNotFound when none).
func (s *Store) scanOne(rows pgx.Rows) (Connection, error) {
	defer rows.Close()
	if !rows.Next() {
		if err := rows.Err(); err != nil {
			return Connection{}, err
		}
		return Connection{}, ErrConnectionNotFound
	}
	return s.scanRow(rows)
}

// scanRow scans the selectConn column list AND decrypts the sealed secret into
// Connection.ClientSecret.
func (s *Store) scanRow(rows pgx.Rows) (Connection, error) {
	var c Connection
	var enc []byte
	if err := rows.Scan(&c.ID, &c.TenantID, &c.OrgID, &c.Provider, &c.Issuer, &c.ClientID,
		&enc, &c.AuthorizeURL, &c.TokenURL, &c.JWKSURL, &c.RedirectURI, &c.EmailDomain,
		&c.DefaultRole, &c.CreatedAt); err != nil {
		return Connection{}, err
	}
	secret, err := s.sealer.open(enc)
	if err != nil {
		return Connection{}, err
	}
	c.ClientSecret = secret
	return c, nil
}
