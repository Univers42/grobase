package github

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"fmt"
)

// flows.go — the connect / status / device-login / link orchestration (the non-sync
// service surface).

// StartConnect mints a single-use pending-connect nonce for orgID and returns it with
// an informational install URL (the Vercel relay builds the real install link).
func (s *Service) StartConnect(ctx context.Context, orgID, userID string) (nonce, installURL string, err error) {
	var raw [16]byte
	if _, err = rand.Read(raw[:]); err != nil {
		return "", "", err
	}
	nonce = hex.EncodeToString(raw[:])
	if err = s.putPending(ctx, nonce, orgID, userID); err != nil {
		return "", "", err
	}
	installURL = fmt.Sprintf("%s/github-apps/installations/new?state=%s", s.cfg.OAuthBase, nonce)
	return nonce, installURL, nil
}

// Callback handles the relay forward: resolve the installation from GitHub, record
// its identity, and mark the pending nonce ready (single-use).
func (s *Service) Callback(ctx context.Context, nonce string, installID int64) error {
	inst, err := s.getInstallation(ctx, installID)
	if err != nil {
		return err
	}
	if err := s.upsertInstallation(ctx, inst); err != nil {
		return err
	}
	return s.markPendingReady(ctx, nonce, installID)
}

// Status reports a pending-connect nonce's state for the CLI poll.
func (s *Service) Status(ctx context.Context, nonce string) (ConnectStatus, error) {
	return s.pendingStatus(ctx, nonce)
}

// DeviceStart proxies GitHub's device-code request (no callback).
func (s *Service) DeviceStart(ctx context.Context) (DeviceStart, error) {
	return s.deviceStart(ctx)
}

// DeviceLogin polls the device code; on approval it reads the GitHub user, discards
// the GitHub token, links the user, and mints a GoTrue session. ErrPending while the
// user has not yet approved.
func (s *Service) DeviceLogin(ctx context.Context, deviceCode string) (string, error) {
	user, err := s.devicePoll(ctx, deviceCode)
	if err != nil {
		return "", err
	}
	subject := githubSubject(user.ID)
	if err := s.upsertUserLink(ctx, user.ID, user.Login, subject); err != nil {
		return "", err
	}
	return s.mintSession(subject)
}

// Link associates a GitHub org login with a vault42 org (idempotent). ErrNotFound if
// no installation exists for that login (connect first).
func (s *Service) Link(ctx context.Context, orgID, githubLogin, userID string) error {
	installID, err := s.installationForOrgLogin(ctx, githubLogin)
	if err != nil {
		return err
	}
	return s.upsertLink(ctx, orgID, installID, userID)
}
