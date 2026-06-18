package sso

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// httpTimeout bounds the IdP token + JWKS calls (an IdP that hangs must not hang
// a login). Net-new HTTP client, no shared state.
const httpTimeout = 10 * time.Second

// buildAuthorizeURL constructs the OIDC authorization-code redirect for a
// connection: response_type=code with scope "openid email profile", carrying the
// single-use state + nonce we minted. The IdP authenticates the user and
// redirects back to redirect_uri with ?code&state; the nonce comes back INSIDE
// the id_token (replay defense, verified in verifyIDToken).
func buildAuthorizeURL(c Connection, state, nonce string) string {
	q := url.Values{}
	q.Set("response_type", "code")
	q.Set("client_id", c.ClientID)
	q.Set("redirect_uri", c.RedirectURI)
	q.Set("scope", "openid email profile")
	q.Set("state", state)
	q.Set("nonce", nonce)
	sep := "?"
	if strings.Contains(c.AuthorizeURL, "?") {
		sep = "&"
	}
	return c.AuthorizeURL + sep + q.Encode()
}

// tokenResponse is the IdP token endpoint reply we read. We only need id_token
// (the JWT we verify); access_token/token_type are read for completeness.
type tokenResponse struct {
	IDToken     string `json:"id_token"`
	AccessToken string `json:"access_token"`
	TokenType   string `json:"token_type"`
	Error       string `json:"error"`
	ErrorDesc   string `json:"error_description"`
}

// exchangeCode POSTs the authorization code to the IdP token endpoint
// (grant_type=authorization_code) and returns the raw id_token JWT. Client
// authentication is form-post (client_id + client_secret), the common OIDC
// confidential-client style the mock IdP and real IdPs both accept.
func exchangeCode(ctx context.Context, c Connection, code string) (string, error) {
	req, err := tokenRequest(ctx, c, code)
	if err != nil {
		return "", err
	}
	client := &http.Client{Timeout: httpTimeout}
	resp, err := client.Do(req)
	if err != nil {
		return "", fmt.Errorf("%w: token endpoint: %v", ErrTokenRejected, err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("%w: token endpoint status %d", ErrTokenRejected, resp.StatusCode)
	}
	return parseTokenResponse(body)
}

// tokenRequest builds the form-encoded authorization-code POST to the IdP token
// endpoint (confidential-client style: client_id + optional client_secret).
func tokenRequest(ctx context.Context, c Connection, code string) (*http.Request, error) {
	form := url.Values{}
	form.Set("grant_type", "authorization_code")
	form.Set("code", code)
	form.Set("redirect_uri", c.RedirectURI)
	form.Set("client_id", c.ClientID)
	if c.ClientSecret != "" {
		form.Set("client_secret", c.ClientSecret)
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.TokenURL,
		strings.NewReader(form.Encode()))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("Accept", "application/json")
	return req, nil
}

// parseTokenResponse reads the IdP token reply and returns the raw id_token JWT,
// mapping any IdP-side error or a missing id_token to ErrTokenRejected.
func parseTokenResponse(body []byte) (string, error) {
	var tr tokenResponse
	if err := json.Unmarshal(body, &tr); err != nil {
		return "", fmt.Errorf("%w: token endpoint body: %v", ErrTokenRejected, err)
	}
	if tr.Error != "" {
		return "", fmt.Errorf("%w: token endpoint error %s %s", ErrTokenRejected, tr.Error, tr.ErrorDesc)
	}
	if tr.IDToken == "" {
		return "", fmt.Errorf("%w: token endpoint returned no id_token", ErrTokenRejected)
	}
	return tr.IDToken, nil
}
