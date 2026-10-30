/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   audit_test.go                                      :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/10/30 14:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/10/30 14:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package gdprsvc

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"slices"
	"testing"
	"time"
)

// A synthetic actor: version-4 shape, never a live id.
const testActor = "00000000-0000-4000-8000-000000000001"

func (f *fakeRepo) eraseAuditActor(_ context.Context, userID string) (int64, error) {
	f.calls = append(f.calls, "erase")
	f.erasedID = userID
	return 2, f.eraseErr
}

func (f *fakeRepo) purgeAuditLog(_ context.Context, days, batch int) (int64, error) {
	f.calls = append(f.calls, "purge")
	if days != 365 || batch != auditPurgeBatch {
		return 0, errors.New("purge called with the wrong days or batch")
	}
	if f.purgeRows == nil {
		return 0, nil
	}
	if len(f.purgeRows) == 0 {
		return 0, errors.New("purge called past the scripted batches")
	}
	n := f.purgeRows[0]
	f.purgeRows = f.purgeRows[1:]
	return n, nil
}

// processAs completes (or moves to status) a pending request of userID and
// records the webhook in the same call log as the repo.
func processAs(f *fakeRepo, userID, status string) int {
	f.delReq = &DeletionRequest{ID: 1, UserID: userID, Status: "pending"}
	svc, _ := newSvc(f)
	svc.doDeletion = func(context.Context, string) { f.calls = append(f.calls, "webhook") }
	rec := do(svc, "POST", "/deletion-requests/admin/1/process", `{"status":"`+status+`"}`, adminHdr())
	return rec.Code
}

// C2(i): the app deletes first, so the erase also catches rows written up to it.
func TestProcessCompletedRunsWebhookThenEraseThenUpdate(t *testing.T) {
	f := &fakeRepo{}
	if code := processAs(f, testActor, "completed"); code != http.StatusOK {
		t.Fatalf("process = %d, want 200", code)
	}
	if want := []string{"webhook", "erase", "update"}; !slices.Equal(f.calls, want) {
		t.Errorf("calls = %v, want %v", f.calls, want)
	}
}

// C2(ii): an erase error is a 5xx and the request keeps its status.
func TestProcessEraseErrorIs5xxAndStatusUnchanged(t *testing.T) {
	f := &fakeRepo{eraseErr: errors.New("connection reset")}
	if code := processAs(f, testActor, "completed"); code != http.StatusInternalServerError {
		t.Fatalf("process with a failing erase = %d, want 500", code)
	}
	if slices.Contains(f.calls, "update") {
		t.Errorf("updateRequest ran after a failed erase: %v", f.calls)
	}
}

// C2(iii): no GDPR_DELETION_WEBHOOK_URL still erases the audit trail.
func TestProcessErasesWithoutWebhookURL(t *testing.T) {
	f := &fakeRepo{delReq: &DeletionRequest{ID: 1, UserID: testActor, Status: "pending"}}
	svc, _ := newSvc(f)
	svc.doDeletion = httpDeletion(http.DefaultClient, "", slog.Default())
	rec := do(svc, "POST", "/deletion-requests/admin/1/process", `{"status":"completed"}`, adminHdr())
	if rec.Code != http.StatusOK || !slices.Equal(f.calls, []string{"erase", "update"}) {
		t.Errorf("unset webhook = %d %v, want 200 [erase update]", rec.Code, f.calls)
	}
}

// C2(iv): only a completed request erases.
func TestProcessNoEraseForInProgressOrRejected(t *testing.T) {
	for _, status := range []string{"in_progress", "rejected"} {
		f := &fakeRepo{}
		code := processAs(f, testActor, status)
		if code != http.StatusOK || !slices.Equal(f.calls, []string{"update"}) {
			t.Errorf("%s = %d %v, want 200 [update]", status, code, f.calls)
		}
	}
}

// C3: a user_id that is not a UUID can never be an audit actor_id.
func TestProcessNonUUIDUserSkipsEraseAndCompletes(t *testing.T) {
	for _, id := range []string{"u-9", "", "00000000-0000-4000-8000-00000000000g"} {
		f := &fakeRepo{eraseErr: errors.New("22P02 if it were called")}
		code := processAs(f, id, "completed")
		if code != http.StatusOK || !slices.Equal(f.calls, []string{"webhook", "update"}) {
			t.Errorf("user_id %q = %d %v, want 200 [webhook update]", id, code, f.calls)
		}
	}
}

// C3: a UUID in another accepted spelling is erased under its canonical
// text, the form audit_log.resource and actor_id::text carry.
func TestProcessErasesNonCanonicalUUIDAsCanonical(t *testing.T) {
	for _, id := range []string{"{" + testActor + "}", "urn:uuid:" + testActor, "00000000000040008000000000000001"} {
		f := &fakeRepo{}
		code := processAs(f, id, "completed")
		if code != http.StatusOK || f.erasedID != testActor {
			t.Errorf("user_id %q = %d, erased %q; want 200, %q", id, code, f.erasedID, testActor)
		}
	}
}

// C6: the knob never crashes; a bad value disables retention and says why.
var retentionCases = []struct {
	raw     string
	want    int
	wantErr bool
}{
	{"", 365, false},
	{"0", 0, false},
	{"30", 30, false},
	{" 400 ", 400, false},
	{"36500", 36500, false},
	{"29", 0, true},
	{"1", 0, true},
	{"-5", 0, true},
	{"1.5", 0, true},
	{"365d", 0, true},
	{"36501", 0, true},
	{"99999999999999999999", 0, true},
}

func TestParseRetentionDays(t *testing.T) {
	for _, c := range retentionCases {
		got, err := parseRetentionDays(c.raw)
		if got != c.want || (err != nil) != c.wantErr {
			t.Errorf("parseRetentionDays(%q) = %d, %v; want %d, err=%v", c.raw, got, err, c.want, c.wantErr)
		}
	}
}

// C5: the caller loops while a batch comes back full and stops on a short one.
func TestPurgeStopsOnShortBatch(t *testing.T) {
	f := &fakeRepo{purgeRows: []int64{auditPurgeBatch, auditPurgeBatch, 7, auditPurgeBatch}}
	svc, _ := newSvc(f)
	svc.retentionDays = 365
	if got := svc.purgeAudit(context.Background()); got != 2*auditPurgeBatch+7 {
		t.Errorf("purged %d, want %d", got, 2*auditPurgeBatch+7)
	}
	if len(f.calls) != 3 {
		t.Errorf("batches = %d, want 3 (stop after the short one)", len(f.calls))
	}
}

// C5: ctx is checked between batches, so shutdown is never held by a backlog.
func TestPurgeStopsWhenCtxCancelled(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	f := &fakeRepo{purgeRows: []int64{auditPurgeBatch, auditPurgeBatch, auditPurgeBatch}}
	svc, _ := newSvc(&cancelOnPurge{fakeRepo: f, cancel: cancel})
	svc.retentionDays = 365
	svc.purgeAudit(ctx)
	if len(f.calls) != 1 {
		t.Errorf("batches after cancel = %d, want 1", len(f.calls))
	}
}

// C1: Run purges at boot when enabled and returns when ctx is cancelled.
func TestRunPurgesAtBootAndStopsOnCancel(t *testing.T) {
	// The timeout only bounds a Run that never purges; the purge cancels first.
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	f := &fakeRepo{}
	svc, _ := newSvc(&cancelOnPurge{fakeRepo: f, cancel: cancel})
	svc.retentionDays = 365
	svc.Run(ctx)
	if !slices.Equal(f.calls, []string{"purge"}) {
		t.Errorf("calls = %v, want one boot purge", f.calls)
	}
}

// C6: disabled (0, or a bad value) never touches audit_log.
func TestRunDisabledNeverPurges(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	f := &fakeRepo{}
	svc, _ := newSvc(f)
	svc.retentionErr = errors.New("AUDIT_LOG_RETENTION_DAYS bad")
	svc.Run(ctx)
	if len(f.calls) != 0 {
		t.Errorf("disabled retention called %v", f.calls)
	}
}

// cancelOnPurge cancels the run context during the first purge batch.
type cancelOnPurge struct {
	*fakeRepo
	cancel context.CancelFunc
}

func (c *cancelOnPurge) purgeAuditLog(ctx context.Context, days, batch int) (int64, error) {
	c.cancel()
	return c.fakeRepo.purgeAuditLog(ctx, days, batch)
}
