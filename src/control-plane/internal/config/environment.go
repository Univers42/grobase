package config

import "strings"

// environmentKey names the env var that states which deployment this is
// (infra/config/env/schema.json, category ENVIRONMENT). Unset or empty = Local.
const environmentKey = "GROBASE_ENV"

// Environment is the deployment's identity. It decides how a missing secret is
// treated: a hard stop in Staging and Prod, tolerated in Local and Dev.
type Environment string

// The four environments schema.json allows for GROBASE_ENV.
const (
	Local   Environment = "local"
	Dev     Environment = "dev"
	Staging Environment = "staging"
	Prod    Environment = "prod"
)

// configErr is a string-backed error so the sentinels below are constants, not
// package variables, and still match errors.Is (no-globals rule).
type configErr string

// Error returns the sentinel's message.
func (e configErr) Error() string { return string(e) }

const (
	// ErrUnknownEnvironment is returned when GROBASE_ENV is set to a value outside
	// the allowed set. The offending value is deliberately not echoed.
	ErrUnknownEnvironment configErr = "GROBASE_ENV is not a known environment (allowed: local, dev, staging, prod)"
	// ErrMissingConfig wraps the aggregated list of keys a service cannot start without.
	ErrMissingConfig configErr = "missing required configuration"
)

// ParseEnvironment maps a raw GROBASE_ENV value to an Environment: empty means
// Local, surrounding whitespace is ignored, and the match is exact and
// lower-case like the schema enum, so a typo such as "Prod" fails closed instead
// of silently becoming Local. Any other value yields ErrUnknownEnvironment.
func ParseEnvironment(raw string) (Environment, error) {
	e := Environment(strings.TrimSpace(raw))
	switch e {
	case "":
		return Local, nil
	case Local, Dev, Staging, Prod:
		return e, nil
	}
	return "", ErrUnknownEnvironment
}

// Strict reports whether a missing required secret must stop the process
// (Staging and Prod). Local and Dev tolerate it.
func (e Environment) Strict() bool {
	return e == Staging || e == Prod
}
