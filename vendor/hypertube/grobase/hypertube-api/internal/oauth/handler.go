package oauth

import (
	"net/http"
	"strings"

	"hypertube/api/internal/httpx"
)

// TokenHandler serves POST /oauth/token (client_credentials grant). It returns
// 415 for the wrong content type, 400 for a bad grant_type, 401 for bad client
// credentials, and 200 with a freshly minted bearer token on success.
func (i *Issuer) TokenHandler(w http.ResponseWriter, r *http.Request) {
	if !formContentType(r) {
		httpx.WriteError(w, http.StatusUnsupportedMediaType, "expected application/x-www-form-urlencoded")
		return
	}
	if err := r.ParseForm(); err != nil {
		httpx.WriteError(w, http.StatusBadRequest, "malformed form body")
		return
	}
	if r.PostForm.Get("grant_type") != "client_credentials" {
		httpx.WriteError(w, http.StatusBadRequest, "unsupported grant_type")
		return
	}
	i.grant(w, r)
}

// grant validates the client credentials and mints a token, mapping a bad pair
// to 401 and a signing failure to 500.
func (i *Issuer) grant(w http.ResponseWriter, r *http.Request) {
	id, secret := r.PostForm.Get("client_id"), r.PostForm.Get("client_secret")
	if !i.ValidClient(id, secret) {
		httpx.WriteError(w, http.StatusUnauthorized, "invalid client credentials")
		return
	}
	tok, err := i.Mint(id)
	if err != nil {
		httpx.WriteError(w, http.StatusInternalServerError, "could not issue token")
		return
	}
	httpx.WriteJSON(w, http.StatusOK, tok)
}

// formContentType reports whether the request body is form-urlencoded.
func formContentType(r *http.Request) bool {
	ct := r.Header.Get("Content-Type")
	return strings.HasPrefix(ct, "application/x-www-form-urlencoded")
}
