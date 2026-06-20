package teams

import (
	"context"
	"encoding/json"
	"log/slog"
	"time"

	"github.com/dlesieur/mini-baas/control-plane/internal/audit"
	"github.com/dlesieur/mini-baas/control-plane/internal/orgs"
	"github.com/dlesieur/mini-baas/control-plane/internal/pg"
)

// orgRoleResolver resolves a caller's org role — the port the token mapper uses to
// bound an org-scoped token to the issuer's org standing. *orgs.Service satisfies it.
type orgRoleResolver interface {
	MemberRole(ctx context.Context, orgID, userID string) (orgs.Role, bool)
}

// auditSink seals one tamper-evident event — the port for the audit chain.
// *audit.Service satisfies it.
type auditSink interface {
	Append(ctx context.Context, in audit.AppendInput) (audit.Event, error)
}

// Service owns teams, team membership, project grants, the effective-permission
// resolver, and scoped tokens. It speaks SQL over the admin (BYPASSRLS) pool — the
// Go capability gate is the first wall, the RLS policies the second. Dependencies
// are injected (no globals); `now` is injectable for deterministic TTL tests.
type Service struct {
	db    *pg.Postgres
	orgs  orgRoleResolver
	audit auditSink
	log   *slog.Logger
	now   func() time.Time
}

// NewService wires the DB pool, the org-role resolver, the audit sink, and a logger.
func NewService(db *pg.Postgres, org orgRoleResolver, aud auditSink, log *slog.Logger) *Service {
	return &Service{db: db, orgs: org, audit: aud, log: log, now: time.Now}
}

// emitAudit best-effort seals an RBAC change onto the org's chain (a failure is
// logged, never fatal — the privileged op already succeeded). The org id is the
// chain partition key.
func (s *Service) emitAudit(ctx context.Context, orgID, actor, action, target string) {
	if s.audit == nil {
		return
	}
	if _, err := s.audit.Append(ctx, audit.AppendInput{
		TenantID: orgID, Actor: actor, Action: action, Target: target,
	}); err != nil && s.log != nil {
		s.log.Warn("teams audit append failed", "err", err, "action", action)
	}
}

// marshalMeta JSON-encodes metadata, defaulting nil to an empty object.
func marshalMeta(meta map[string]any) string {
	if meta == nil {
		meta = map[string]any{}
	}
	b, _ := json.Marshal(meta)
	return string(b)
}
