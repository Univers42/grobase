/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   selfserve_apps_manage.go                           :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/28 12:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/28 12:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package tenants

import (
	"errors"
	"net/http"

	"github.com/dlesieur/mini-baas/control-plane/internal/httpx"
)

// listApps returns the calling account's apps (its app-tenants tagged with account_user_id).
func (a *appRoutes) listApps(w http.ResponseWriter, r *http.Request) {
	userID, ok := a.auth.AuthUser(w, r)
	if !ok {
		return
	}
	apps, err := a.svc.ListByAccount(r.Context(), userID)
	if err != nil {
		httpx.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	out := make([]map[string]any, 0, len(apps))
	for _, t := range apps {
		out = append(out, map[string]any{
			"app_id": t.ID, "name": t.Name, "status": t.Status, "created_at": t.CreatedAt,
		})
	}
	httpx.WriteJSON(w, http.StatusOK, out)
}

// deleteApp soft-deletes an app the calling account owns. A non-owned or unknown app id returns
// 404 (owner-miss is indistinguishable from not-found, so existence never leaks).
func (a *appRoutes) deleteApp(w http.ResponseWriter, r *http.Request) {
	userID, ok := a.auth.AuthUser(w, r)
	if !ok {
		return
	}
	t, err := a.svc.FindOne(r.Context(), r.PathValue("appId"))
	if err != nil {
		if errors.Is(err, ErrNotFound) {
			httpx.WriteError(w, http.StatusNotFound, "not_found", "no such app")
			return
		}
		httpx.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	if acct, _ := t.Metadata["account_user_id"].(string); acct != userID {
		httpx.WriteError(w, http.StatusNotFound, "not_found", "no such app")
		return
	}
	if err := a.svc.SoftDelete(r.Context(), t.ID); err != nil {
		httpx.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
