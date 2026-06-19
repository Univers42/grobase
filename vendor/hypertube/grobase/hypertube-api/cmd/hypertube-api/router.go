package main

import (
	"net/http"

	"hypertube/api/internal/comments"
	"hypertube/api/internal/movies"
	"hypertube/api/internal/oauth"
	"hypertube/api/internal/store"
	"hypertube/api/internal/users"
)

// newRouter wires the public token endpoint and the bearer-guarded resource
// routes (users/movies/comments) onto one mux. The 1.22 method-pattern mux yields
// 405 for a known path + wrong method and 404 for any unknown path automatically.
func newRouter(iss *oauth.Issuer, st store.Store) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("POST /oauth/token", iss.TokenHandler)
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		_, _ = w.Write([]byte(`{"ok":true}`))
	})
	mux.Handle("/", iss.RequireBearer(protectedRoutes(st)))
	return mux
}

// protectedRoutes builds the bearer-guarded resource sub-mux (everything except
// /oauth/token and /healthz).
func protectedRoutes(st store.Store) http.Handler {
	mux := http.NewServeMux()
	mountUsers(mux, users.New(st))
	mountMovies(mux, movies.New(st))
	mountComments(mux, comments.New(st))
	return mux
}

// mountUsers binds the /users routes.
func mountUsers(mux *http.ServeMux, h *users.Handler) {
	mux.HandleFunc("GET /users", h.List)
	mux.HandleFunc("GET /users/{id}", h.Get)
	mux.HandleFunc("PATCH /users/{id}", h.Patch)
}

// mountMovies binds the /movies routes (incl. the nested comment-create route).
func mountMovies(mux *http.ServeMux, h *movies.Handler) {
	mux.HandleFunc("GET /movies", h.List)
	mux.HandleFunc("GET /movies/{id}", h.Get)
}

// mountComments binds the /comments routes and POST /movies/{movie_id}/comments.
func mountComments(mux *http.ServeMux, h *comments.Handler) {
	mux.HandleFunc("GET /comments", h.List)
	mux.HandleFunc("GET /comments/{id}", h.Get)
	mux.HandleFunc("POST /comments", h.Create)
	mux.HandleFunc("POST /movies/{movie_id}/comments", h.Create)
	mux.HandleFunc("PATCH /comments/{id}", h.Patch)
	mux.HandleFunc("DELETE /comments/{id}", h.Delete)
}
