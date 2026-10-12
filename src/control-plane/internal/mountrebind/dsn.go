// Package mountrebind re-targets the tenant_databases connection strings of a seed at
// another deployment: a DSN that names the platform login of a platform engine gets the
// target's password and is re-encrypted under the target's VAULT_ENC_KEY. Mount ids, names
// and every other byte of the dump stay as they were.
package mountrebind

import (
	"net/url"
	"slices"
	"strconv"
	"strings"
)

// Target is one platform engine login on the deployment the seed is moving to.
type Target struct {
	Engine   string   `json:"engine"`
	Schemes  []string `json:"schemes"`
	Hosts    []string `json:"hosts"`
	Port     int      `json:"port"`
	User     string   `json:"user"`
	Password string   `json:"password"`
}

// Outcome says what happened to one connection string.
type Outcome string

// The outcomes a row can end in. A row the source key opens is re-sealed under the target
// key whatever its outcome, except Refused; the "kept" ones keep their DSN byte for byte.
const (
	Rebound       Outcome = "rebound: target password written"
	NoCredentials Outcome = "kept: engine carries no credentials"
	NoTarget      Outcome = "kept: no target login for this engine"
	Unmatched     Outcome = "kept: scheme, host, port or user is not the platform login"
	Unparsable    Outcome = "kept: DSN does not parse"
	Refused       Outcome = "refused: target password cannot be written into this DSN form"
	NoCiphertext  Outcome = "untouched: row carries no ciphertext"
	Undecryptable Outcome = "untouched: source key does not open it"
)

// RewriteDSN returns dsn with the target's password when its scheme, host, port and user
// are exactly the target's platform login for engine; otherwise it returns dsn unchanged.
func RewriteDSN(engine, dsn string, targets []Target) (string, Outcome) {
	i := slices.IndexFunc(targets, func(t Target) bool { return t.Engine == engine })
	switch {
	case engine == "sqlite" || engine == "dynamodb":
		return dsn, NoCredentials
	case i < 0:
		return dsn, NoTarget
	case engine == "mssql":
		return rewriteMSSQL(dsn, targets[i])
	}
	return rewriteURL(dsn, targets[i])
}

// rewriteURL handles the engines whose adapters parse the DSN as a URL: url.UserPassword
// percent-encodes the password and the adapter decodes it again.
func rewriteURL(dsn string, t Target) (string, Outcome) {
	u, err := url.Parse(dsn)
	if err != nil || u.Host == "" {
		return dsn, Unparsable
	}
	if !matches(t, u.Scheme, u.Hostname(), u.Port(), u.User.Username()) {
		return dsn, Unmatched
	}
	u.User = url.UserPassword(t.User, t.Password)
	if t.User == "" && t.Password == "" {
		u.User = nil
	}
	return u.String(), Rebound
}

// rewriteMSSQL mirrors data-plane-pool's mssql_config: the DSN is split raw at the first
// '@' and the credentials at the first ':', with no percent-decoding, so a target password
// holding '@' (or a user holding ':') would move a split and is refused rather than written.
func rewriteMSSQL(dsn string, t Target) (string, Outcome) {
	scheme, rest, ok := strings.Cut(dsn, "://")
	creds, hostpart, found := strings.Cut(rest, "@")
	if !ok || !found {
		return dsn, Unparsable
	}
	user, _, _ := strings.Cut(creds, ":")
	hostPort, _, _ := strings.Cut(hostpart, "/")
	host, port, _ := strings.Cut(hostPort, ":")
	if !matches(t, scheme, host, port, user) {
		return dsn, Unmatched
	}
	if strings.Contains(t.Password, "@") || strings.Contains(t.User, ":") {
		return dsn, Refused
	}
	return scheme + "://" + t.User + ":" + t.Password + "@" + hostpart, Rebound
}

// matches compares one parsed DSN with a target; an absent port means the engine default,
// which is the target's Port.
func matches(t Target, scheme, host, port, user string) bool {
	want := strconv.Itoa(t.Port)
	if port == "" {
		port = want
	}
	return slices.Contains(t.Schemes, scheme) && slices.Contains(t.Hosts, host) &&
		port == want && user == t.User
}
