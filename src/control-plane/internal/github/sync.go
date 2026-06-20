package github

import (
	"context"

	"github.com/dlesieur/mini-baas/control-plane/internal/teams"
)

// sync.go — map a GitHub org's structure into the vault42 model: members → org
// members, teams → teams, team membership → team membership. GitHub is the source of
// truth for STRUCTURE; vault42 owns the final RBAC. Every write is idempotent (re-sync
// converges). A member's GoTrue subject is the deterministic githubSubject(id), so a
// later `auth login --github` resolves to the SAME subject.
//
// ponytail: repo→project-role seeding (provision a tenant per repo + map repo
// collaborator tiers to project grants) is a follow-up — it needs the provisioning
// reconciler + per-repo collaborator reads. v1 syncs the org/team/member structure.

// Sync mints an installation token just-in-time, reads the GitHub org's structure,
// and upserts it. The token is discarded at return (never persisted).
func (s *Service) Sync(ctx context.Context, orgID string) (SyncSummary, error) {
	installID, err := s.linkInstallation(ctx, orgID)
	if err != nil {
		return SyncSummary{}, err
	}
	inst, err := s.getInstallation(ctx, installID)
	if err != nil {
		return SyncSummary{}, err
	}
	instTok, err := s.installationToken(ctx, installID)
	if err != nil {
		return SyncSummary{}, err
	}
	members, err := s.listOrgMembers(ctx, instTok, inst.OrgLogin)
	if err != nil {
		return SyncSummary{}, err
	}
	for _, m := range members {
		_ = s.orgs.AddMember(ctx, orgID, githubSubject(m.ID), s.cfg.DefaultRole, "github_sync")
	}
	teamCount, err := s.syncTeams(ctx, orgID, instTok, inst.OrgLogin)
	if err != nil {
		return SyncSummary{}, err
	}
	_, _ = s.execTag(ctx, `UPDATE public.github_links SET last_synced_at=now() WHERE org_id::text=$1 AND installation_id=$2`, orgID, installID)
	return SyncSummary{Teams: teamCount, Members: len(members)}, nil
}

// syncTeams upserts each GitHub team + its membership, returning the team count.
func (s *Service) syncTeams(ctx context.Context, orgID, instTok, orgLogin string) (int, error) {
	ghTeams, err := s.listOrgTeams(ctx, instTok, orgLogin)
	if err != nil {
		return 0, err
	}
	bySlug, err := s.teamSlugIndex(ctx, orgID)
	if err != nil {
		return 0, err
	}
	count := 0
	for _, t := range ghTeams {
		teamID := bySlug[t.Slug]
		if teamID == "" {
			created, err := s.teams.CreateTeam(ctx, orgID, teams.CreateTeamRequest{Slug: t.Slug, Name: t.Name}, "github_sync")
			if err != nil {
				continue
			}
			teamID = created.ID
		}
		count++
		tmembers, _ := s.listTeamMembers(ctx, instTok, orgLogin, t.Slug)
		for _, tm := range tmembers {
			_ = s.teams.AddTeamMember(ctx, orgID, teamID, teams.AddTeamMemberRequest{UserID: githubSubject(tm.ID)}, "github_sync")
		}
	}
	return count, nil
}

// teamSlugIndex returns the org's existing team slugs → ids (for idempotent sync).
func (s *Service) teamSlugIndex(ctx context.Context, orgID string) (map[string]string, error) {
	list, err := s.teams.ListTeams(ctx, orgID)
	if err != nil {
		return nil, err
	}
	out := make(map[string]string, len(list))
	for _, t := range list {
		out[t.Slug] = t.ID
	}
	return out, nil
}
