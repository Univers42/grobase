// Package newslettersvc is the Go port of the Node newsletter-service (R2).
//
// It owns the `newsletter.subscriber` + `newsletter.send_log` tables and ports
// both NestJS controllers: subscription (subscribe / confirm / unsubscribe +
// admin list/stats) and campaign (admin send / history). Outbound confirmation
// and campaign mail goes through an emailSender seam — by default an HTTP POST
// to EMAIL_SERVICE_URL/send, identical to the Node fetch — so behavior is
// byte-faithful and the seam is fakeable in tests. Running it inside the
// orchestrator binary instead of a ~50 MiB Node runtime is the R2 footprint win.
//
// Admin routes require role `service_role` (parity with the TS RolesGuard);
// public subscribe/confirm/unsubscribe are open, matching the Node controller.
package newslettersvc

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
)

// emailSender abstracts the outbound /send call (fakeable in tests).
type emailSender func(ctx context.Context, to, subject, html, text string) error

// repo is the newsletter persistence seam (satisfied by *store; faked in tests).
type repo interface {
	bootstrap(ctx context.Context) error
	existing(ctx context.Context, email string) (int64, bool, *string, bool, error)
	reactivate(ctx context.Context, id int64, token string, firstName *string) (*Subscriber, error)
	insert(ctx context.Context, email string, firstName *string, token string) (*Subscriber, error)
	confirm(ctx context.Context, token string) (bool, error)
	unsubscribe(ctx context.Context, token string) (bool, error)
	listSubscribers(ctx context.Context, limit, offset int) ([]SubscriberSummary, error)
	stats(ctx context.Context) (Stats, error)
	confirmedEmails(ctx context.Context) ([]Recipient, error)
	logSend(ctx context.Context, subject string, count int, sentBy *string) error
	history(ctx context.Context, limit int) ([]SendLog, error)
}

// Service is the newsletter sub-service.
type Service struct {
	log       *slog.Logger
	store     repo
	send      emailSender
	baseURL   string // NEWSLETTER_BASE_URL — confirm links
	batchSize int    // NEWSLETTER_BATCH_SIZE
}

// New builds the service from env. The default email seam posts to
// EMAIL_SERVICE_URL/send (parity with the Node fetch).
func New(log *slog.Logger, pg *shared.Postgres) *Service {
	emailURL := env("EMAIL_SERVICE_URL", "http://email-service:3030")
	client := &http.Client{Timeout: 10 * time.Second}
	return &Service{
		log:       log,
		store:     &store{pg: pg},
		baseURL:   env("NEWSLETTER_BASE_URL", "http://localhost:8000/newsletter/v1"),
		batchSize: envInt("NEWSLETTER_BATCH_SIZE", 5),
		send:      httpEmailSender(client, emailURL),
	}
}

// Name identifies the sub-service to the orchestrator.
func (s *Service) Name() string { return "newsletter" }

// Init ensures the newsletter tables exist (parity with onModuleInit).
func (s *Service) Init(ctx context.Context) error {
	if err := s.store.bootstrap(ctx); err != nil {
		return err
	}
	s.log.Info("newsletter tables ensured")
	return nil
}

// Mount registers the HTTP surface.
func (s *Service) Mount(mux *http.ServeMux) {
	mux.HandleFunc("POST /subscribe", s.subscribe)
	mux.HandleFunc("GET /confirm/{token}", s.confirm)
	mux.HandleFunc("GET /unsubscribe/{token}", s.unsubscribe)
	mux.HandleFunc("GET /admin/subscribers", s.adminSubscribers)
	mux.HandleFunc("GET /admin/stats", s.adminStats)
	mux.HandleFunc("POST /admin/campaigns/send", s.campaignSend)
	mux.HandleFunc("GET /admin/campaigns/history", s.campaignHistory)
}

// Run has no background loop; it parks until shutdown.
func (s *Service) Run(ctx context.Context) { <-ctx.Done() }

/* ─────── Subscription ─────── */

func (s *Service) subscribe(w http.ResponseWriter, r *http.Request) {
	var b struct {
		Email     string `json:"email"`
		FirstName string `json:"firstName"`
	}
	if err := json.NewDecoder(r.Body).Decode(&b); err != nil || !validEmail(b.Email) {
		writeErr(w, http.StatusBadRequest, "validation_error", "a valid email is required")
		return
	}
	ctx := r.Context()
	id, active, existingFirst, found, err := s.store.existing(ctx, b.Email)
	if s.fail(w, err) {
		return
	}
	first := optional(b.FirstName)
	if found {
		if active {
			writeErr(w, http.StatusConflict, "conflict", "This email is already subscribed")
			return
		}
		token := newToken()
		sub, err := s.store.reactivate(ctx, id, token, first)
		if s.fail(w, err) {
			return
		}
		s.notifyConfirmation(ctx, b.Email, firstOr(b.FirstName, existingFirst), token)
		writeJSON(w, http.StatusCreated, map[string]any{"reactivated": true, "subscriber": sub})
		return
	}
	token := newToken()
	sub, err := s.store.insert(ctx, b.Email, first, token)
	if s.fail(w, err) {
		return
	}
	s.notifyConfirmation(ctx, b.Email, b.FirstName, token)
	writeJSON(w, http.StatusCreated, map[string]any{"subscribed": true, "subscriber": sub})
}

func (s *Service) confirm(w http.ResponseWriter, r *http.Request) {
	ok, err := s.store.confirm(r.Context(), r.PathValue("token"))
	if s.fail(w, err) {
		return
	}
	if !ok {
		writeErr(w, http.StatusNotFound, "not_found", "Invalid or already-used token")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"confirmed": true})
}

func (s *Service) unsubscribe(w http.ResponseWriter, r *http.Request) {
	ok, err := s.store.unsubscribe(r.Context(), r.PathValue("token"))
	if s.fail(w, err) {
		return
	}
	if !ok {
		writeErr(w, http.StatusNotFound, "not_found", "Invalid token")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"unsubscribed": true})
}

func (s *Service) adminSubscribers(w http.ResponseWriter, r *http.Request) {
	if !requireAdmin(w, r) {
		return
	}
	limit := queryInt(r, "limit", 100)
	offset := queryInt(r, "offset", 0)
	out, err := s.store.listSubscribers(r.Context(), limit, offset)
	if s.fail(w, err) {
		return
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Service) adminStats(w http.ResponseWriter, r *http.Request) {
	if !requireAdmin(w, r) {
		return
	}
	st, err := s.store.stats(r.Context())
	if s.fail(w, err) {
		return
	}
	writeJSON(w, http.StatusOK, st)
}

/* ─────── Campaign (all admin) ─────── */

func (s *Service) campaignSend(w http.ResponseWriter, r *http.Request) {
	userID, ok := requireAdminUser(w, r)
	if !ok {
		return
	}
	var b struct {
		Subject string `json:"subject"`
		HTML    string `json:"html"`
		Text    string `json:"text"`
	}
	if err := json.NewDecoder(r.Body).Decode(&b); err != nil ||
		strings.TrimSpace(b.Subject) == "" || strings.TrimSpace(b.HTML) == "" {
		writeErr(w, http.StatusBadRequest, "validation_error", "subject and html are required")
		return
	}
	sent, failed, err := s.sendCampaign(r.Context(), b.Subject, b.HTML, b.Text, userID)
	if s.fail(w, err) {
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"sent": sent, "failed": failed})
}

// sendCampaign fans the campaign out to every confirmed subscriber and records
// the send. Recipients are sent in batches of batchSize (parity with the Node
// Promise.allSettled batching); a non-2xx or transport error counts as failed.
func (s *Service) sendCampaign(ctx context.Context, subject, html, text, sentBy string) (int, int, error) {
	recipients, err := s.store.confirmedEmails(ctx)
	if err != nil {
		return 0, 0, err
	}
	if len(recipients) == 0 {
		s.log.Warn("no confirmed subscribers — skipping campaign send")
		return 0, 0, nil
	}
	sent, failed := 0, 0
	for i := 0; i < len(recipients); i += s.batchSize {
		end := i + s.batchSize
		if end > len(recipients) {
			end = len(recipients)
		}
		for _, rcpt := range recipients[i:end] {
			if err := s.send(ctx, rcpt.Email, subject, html, text); err != nil {
				failed++
			} else {
				sent++
			}
		}
	}
	if err := s.store.logSend(ctx, subject, sent, optional(sentBy)); err != nil {
		return sent, failed, err
	}
	s.log.Info("campaign sent", "subject", subject, "sent", sent, "failed", failed)
	return sent, failed, nil
}

func (s *Service) campaignHistory(w http.ResponseWriter, r *http.Request) {
	if !requireAdmin(w, r) {
		return
	}
	out, err := s.store.history(r.Context(), queryInt(r, "limit", 50))
	if s.fail(w, err) {
		return
	}
	writeJSON(w, http.StatusOK, out)
}

// notifyConfirmation fires the confirmation email; failures are logged and
// swallowed (parity with the Node try/catch — subscribe still succeeds).
func (s *Service) notifyConfirmation(ctx context.Context, email, firstName, token string) {
	greeting := ""
	if firstName != "" {
		greeting = " " + firstName
	}
	confirmURL := strings.TrimRight(s.baseURL, "/") + "/confirm/" + token
	html := "<p>Hello" + greeting + ",</p>\n" +
		"<p>Please confirm your subscription by clicking the link below:</p>\n" +
		`<p><a href="` + confirmURL + `">Confirm subscription</a></p>` + "\n" +
		"<p>If you did not subscribe, you can safely ignore this email.</p>"
	if err := s.send(ctx, email, "Confirm your newsletter subscription", html, ""); err != nil {
		s.log.Error("failed to send confirmation email", "err", err)
	}
}

/* ─────── helpers ─────── */

func (s *Service) fail(w http.ResponseWriter, err error) bool {
	switch {
	case err == nil:
		return false
	case errors.Is(err, errConflict):
		writeErr(w, http.StatusConflict, "conflict", "This email is already subscribed")
	case errors.Is(err, errNotFound):
		writeErr(w, http.StatusNotFound, "not_found", "invalid token")
	default:
		s.log.Error("newsletter store error", "err", err)
		writeErr(w, http.StatusInternalServerError, "internal_error", "unexpected error")
	}
	return true
}

// httpEmailSender posts {to,subject,html,text} to <url>/send. A non-2xx is an
// error (counts as a campaign failure), matching the Node `r.value.ok` check.
func httpEmailSender(client *http.Client, url string) emailSender {
	endpoint := strings.TrimRight(url, "/") + "/send"
	return func(ctx context.Context, to, subject, html, text string) error {
		body, _ := json.Marshal(map[string]string{"to": to, "subject": subject, "html": html, "text": text})
		req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(body))
		if err != nil {
			return err
		}
		req.Header.Set("Content-Type", "application/json")
		resp, err := client.Do(req)
		if err != nil {
			return err
		}
		defer func() { _ = resp.Body.Close() }()
		if resp.StatusCode < 200 || resp.StatusCode >= 300 {
			return errors.New("email-service returned " + resp.Status)
		}
		return nil
	}
}

func requireAdmin(w http.ResponseWriter, r *http.Request) bool {
	_, ok := requireAdminUser(w, r)
	return ok
}

// requireAdminUser enforces service_role and returns the caller's user id (used
// as send_log.sent_by for campaigns).
func requireAdminUser(w http.ResponseWriter, r *http.Request) (string, bool) {
	userID := r.Header.Get("X-Baas-User-Id")
	if userID == "" {
		userID = r.Header.Get("X-User-Id")
	}
	if userID == "" {
		writeErr(w, http.StatusUnauthorized, "unauthorized", "missing verified identity")
		return "", false
	}
	if r.Header.Get("X-Baas-Role") != "service_role" {
		writeErr(w, http.StatusForbidden, "forbidden", "requires one of: service_role")
		return "", false
	}
	return userID, true
}

func newToken() string {
	buf := make([]byte, 32)
	if _, err := rand.Read(buf); err != nil {
		return strconv.FormatInt(time.Now().UnixNano(), 16)
	}
	return hex.EncodeToString(buf)
}

func validEmail(s string) bool {
	at := strings.IndexByte(s, '@')
	return at > 0 && at < len(s)-1 && len(s) <= 255 &&
		strings.IndexByte(s[at+1:], '.') >= 0 && !strings.ContainsAny(s, " \t")
}

func optional(s string) *string {
	if s == "" {
		return nil
	}
	return &s
}

func firstOr(first string, fallback *string) string {
	if first != "" {
		return first
	}
	if fallback != nil {
		return *fallback
	}
	return ""
}

func queryInt(r *http.Request, key string, def int) int {
	if v := r.URL.Query().Get(key); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
	}
	return def
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeErr(w http.ResponseWriter, status int, code, msg string) {
	writeJSON(w, status, map[string]any{"error": code, "message": msg, "statusCode": status})
}

func env(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func envInt(key string, def int) int {
	if v := os.Getenv(key); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
	}
	return def
}
