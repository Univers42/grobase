package compliance

import (
	"bufio"
	"context"
	"encoding/json"
	"os"
	"sort"
	"strings"
)

// accessGrant is one observed role grant: which role can do what on which
// sensitive control table.
type accessGrant struct {
	Role      string `json:"role"`
	Table     string `json:"table"`
	Privilege string `json:"privilege"`
}

// accessReviewSQL reads role grants on the sensitive control tables from the
// live catalog — the actual, observable access posture (not an assertion). It
// scopes to the platform's control tables so the review is meaningful and small,
// and now covers the newer enterprise-control surface (audit trail, GDPR erasure
// receipts, WebAuthn credentials, SSO/SCIM, CMEK-bearing mounts, ABAC policies)
// so the access section evidences the broader certification surface.
//
// The list is a FIXED, in-query allowlist of ACTUAL table names verified against
// the migrations (047/048/050/051/053/054 create their tables; CMEK lives as
// columns on public.tenant_databases (061) and ABAC conditions on
// public.resource_policies (063), so those real tables are listed rather than
// the non-existent "tenant_database_cmek"/"permission_conditions"). It is
// engine-agnostic ANSI SQL over information_schema.
const accessReviewSQL = `
SELECT grantee, table_name, privilege_type
  FROM information_schema.role_table_grants
 WHERE table_schema = 'public'
   AND table_name IN (
     'compliance_evidence','tenant_audit_log','tenants',
     'tenant_usage','tenant_billing','tenant_backups',
     'erasure_receipts','webauthn_credentials',
     'sso_connections','scim_tokens','scim_users',
     'tenant_databases','resource_policies')
   AND grantee NOT IN ('PUBLIC')
 ORDER BY grantee, table_name, privilege_type`

func (c *Collector) collectAccess(ctx context.Context) (json.RawMessage, error) {
	grants := []accessGrant{}
	rows, err := c.db.AdminQuery(ctx, accessReviewSQL)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var g accessGrant
		if err := rows.Scan(&g.Role, &g.Table, &g.Privilege); err != nil {
			return nil, err
		}
		grants = append(grants, g)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	// authenticated MUST NOT be able to read compliance_evidence — surface that
	// as an explicit, checkable invariant in the evidence itself.
	authedCanReadEvidence := false
	for _, g := range grants {
		if g.Role == "authenticated" && g.Table == "compliance_evidence" && g.Privilege == "SELECT" {
			authedCanReadEvidence = true
		}
	}
	return json.Marshal(map[string]any{
		"control_type":             "access_review",
		"grants_total":             len(grants),
		"grants":                   grants,
		"evidence_is_service_only": !authedCanReadEvidence,
	})
}

// ───────────────────────── change management ─────────────────────────────────

// commit is one change-management record: a commit's short hash, author, and
// subject — the audit trail of WHO changed WHAT.
type commit struct {
	Hash    string `json:"hash"`
	Author  string `json:"author"`
	Subject string `json:"subject"`
}

// collectChangeMgmt reads the git change-log snapshot file. Each line is one
// commit in the pipe-delimited form `<hash>|<author>|<subject>` (the format a
// `git log --pretty=format:'%h|%an|%s'` dump produces). git is not in the
// distroless runtime, so the deploy mounts the trail as a snapshot file; when no
// file is configured the section evidences zero commits (an honest "no trail
// available" rather than a fabricated green).
func (c *Collector) collectChangeMgmt() (json.RawMessage, error) {
	commits := []commit{}
	if c.gitLogPath == "" {
		return c.marshalChange(commits, "")
	}
	f, err := os.Open(c.gitLogPath)
	if err != nil {
		if os.IsNotExist(err) {
			return c.marshalChange(commits, c.gitLogPath)
		}
		return nil, err
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" {
			continue
		}
		parts := strings.SplitN(line, "|", 3)
		cm := commit{Hash: parts[0]}
		if len(parts) > 1 {
			cm.Author = parts[1]
		}
		if len(parts) > 2 {
			cm.Subject = parts[2]
		}
		commits = append(commits, cm)
	}
	if err := sc.Err(); err != nil {
		return nil, err
	}
	return c.marshalChange(commits, c.gitLogPath)
}

func (c *Collector) marshalChange(commits []commit, src string) (json.RawMessage, error) {
	authors := map[string]bool{}
	for _, cm := range commits {
		if cm.Author != "" {
			authors[cm.Author] = true
		}
	}
	uniq := make([]string, 0, len(authors))
	for a := range authors {
		uniq = append(uniq, a)
	}
	sort.Strings(uniq)
	return json.Marshal(map[string]any{
		"control_type":    "change_management",
		"commits_total":   len(commits),
		"authors":         uniq,
		"commits":         commits,
		"source_gitlog":   src,
		"trail_available": len(commits) > 0,
	})
}

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
func isTruthy(v string) bool {
	switch strings.ToLower(strings.TrimSpace(v)) {
	case "1", "true", "yes", "on":
		return true
	default:
		return false
	}
}
