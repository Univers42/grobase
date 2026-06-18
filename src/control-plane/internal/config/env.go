package config

import (
	"os"
	"strconv"
)

// Environment-variable readers shared across the control plane. These were
// previously copy-pasted as unexported helpers in ~15 packages; they live here
// so the flag-gate read is defined once (one source of truth) and every plane
// interprets a variable the same way.

// EnvBool reports whether key is set to a truthy value ("1", "true", "on",
// case-insensitively for those forms). Unset or any other value is false. This
// is the canonical flag-gate read: a cloud/enterprise route mounts only when its
// flag is truthy, so a missing var means byte-parity with the OSS edition.
func EnvBool(key string) bool {
	switch os.Getenv(key) {
	case "1", "true", "on", "TRUE", "True", "ON":
		return true
	default:
		return false
	}
}

// EnvBoolDefault is EnvBool but returns def when key is unset.
func EnvBoolDefault(key string, def bool) bool {
	if os.Getenv(key) == "" {
		return def
	}
	return EnvBool(key)
}

// EnvInt returns key parsed as an int, or def when key is unset or unparseable.
func EnvInt(key string, def int) int {
	if v := os.Getenv(key); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
	}
	return def
}

// EnvStr returns key, or def when key is unset or empty.
func EnvStr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}
