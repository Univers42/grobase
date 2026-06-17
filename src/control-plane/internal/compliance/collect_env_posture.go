package compliance

import (
	"encoding/json"
	"strings"
)

// ───────────────────────── GDPR data-subject rights ──────────────────────────

// collectGDPRRights records whether the GDPR data-subject-rights routes are
// mounted/enabled, read from the flags the running process sees:
//   - erase  (Art.17 "right to erasure")    ← HARD_ERASE_ENABLED
//   - export (Art.20 "right to portability") ← TENANT_EXPORT_ENABLED
//
// It records the OBSERVED posture, never an assertion of compliance: a disabled
// route records enabled:false. all_rights_available is true only when BOTH are
// observably on — so a disabled control can never read as green.
func (c *Collector) collectGDPRRights() (json.RawMessage, error) {
	erase := isTruthy(c.env("HARD_ERASE_ENABLED"))
	export := isTruthy(c.env("TENANT_EXPORT_ENABLED"))
	return json.Marshal(map[string]any{
		"control_type": "gdpr_rights",
		"rights": []map[string]any{
			{"right": "erasure", "article": "GDPR Art.17", "flag": "HARD_ERASE_ENABLED", "enabled": erase},
			{"right": "portability", "article": "GDPR Art.20", "flag": "TENANT_EXPORT_ENABLED", "enabled": export},
		},
		"erase_enabled":        erase,
		"export_enabled":       export,
		"all_rights_available": erase && export,
	})
}

// ───────────────────────── cryptography posture ──────────────────────────────

// collectCryptoPosture records the observable cryptography posture: whether
// CMEK/BYOK envelope encryption is enabled (CMEK_ENABLED) and the transport
// security mode the process runs in (SECURITY_MODE, recorded verbatim; "" =
// unset/not observable). It asserts nothing about strength — it records what the
// process is configured with, so a disabled control reads cmek_enabled:false.
func (c *Collector) collectCryptoPosture() (json.RawMessage, error) {
	cmek := isTruthy(c.env("CMEK_ENABLED"))
	securityMode := c.env("SECURITY_MODE")
	return json.Marshal(map[string]any{
		"control_type":      "crypto_posture",
		"cmek_enabled":      cmek,
		"cmek_flag":         "CMEK_ENABLED",
		"security_mode":     securityMode,
		"security_mode_set": securityMode != "",
	})
}

// ───────────────────────── backup / recovery posture ─────────────────────────

// collectBackupPosture records the observable backup/recovery posture: any
// PITR/retention config the process exposes (PG_BACKUP_PITR, BACKUP_RETENTION /
// PG_BACKUP_RETENTION). When NO backup env is observable it still records the
// static mechanism fact (m87 logical per-tenant backup + m99 restore) so the
// section is never vacuous — but `pitr_enabled`/`retention_configured` reflect
// REALITY, so an unconfigured deploy reads pitr_enabled:false.
func (c *Collector) collectBackupPosture() (json.RawMessage, error) {
	pitr := isTruthy(c.env("PG_BACKUP_PITR"))
	retention := c.env("BACKUP_RETENTION")
	if retention == "" {
		retention = c.env("PG_BACKUP_RETENTION")
	}
	return json.Marshal(map[string]any{
		"control_type":         "backup_posture",
		"pitr_enabled":         pitr,
		"pitr_flag":            "PG_BACKUP_PITR",
		"retention":            retention,
		"retention_configured": retention != "",
		// Static, always-true mechanism fact: the platform SHIPS logical per-tenant
		// backup (m87) + restore (m99). This is a capability statement, not a
		// "configured/enabled" claim — the flags above carry the live posture.
		"mechanism": "m87-logical-per-tenant-backup;m99-restore",
	})
}

// isTruthy parses a boolean-ish env value the same way the Go control plane's
// envBool does (1/true/yes/on, case-insensitive). An unset/empty value is false,
// so a missing flag records the control disabled — never green by omission.
//
// ponytail: kept local (not config.EnvBool) because it parses an already-fetched
// string via the collector's indirected env source — promote to shared if a
// string-input variant is added there.
func isTruthy(v string) bool {
	switch strings.ToLower(strings.TrimSpace(v)) {
	case "1", "true", "yes", "on":
		return true
	default:
		return false
	}
}
