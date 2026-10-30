/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   service_gate.go                                    :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/10/30 17:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/10/30 17:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package adapterregistry

import (
	"log/slog"
	"net/http"
	"os"
	"strings"

	"github.com/dlesieur/mini-baas/control-plane/internal/httpx"
)

// N-22 (devil D2, 2026-10-30): register/list/findOne/descriptor trusted the asserted
// identity header with no service auth, so anything that reaches the registry could
// register or enumerate mounts. The gate is staged because Kong /admin/v1/databases and
// operator scripts still call these routes unsigned: off is today, shadow logs every
// unsigned call without refusing it, and enforce answers 401. Enforce needs 24 h of
// shadow with zero unsigned calls.
const (
	serviceGateEnv     = "ADAPTER_REGISTRY_REQUIRE_SERVICE_AUTH"
	serviceGateShadow  = "shadow"
	serviceGateEnforce = "enforce"
	serviceGateLogMsg  = "adapter-registry unsigned call (service auth shadow)"
)

// serviceGateStage reads the stage; empty or unknown values degrade to "off" so a
// typo never refuses traffic.
func serviceGateStage() string {
	switch v := strings.ToLower(strings.TrimSpace(os.Getenv(serviceGateEnv))); v {
	case serviceGateShadow, serviceGateEnforce:
		return v
	default:
		return "off"
	}
}

// requireService applies the staged gate. It returns false only under enforce, after
// writing 401. The shadow log carries the route pattern and peer address, never a header.
func (rt *routes) requireService(w http.ResponseWriter, r *http.Request) bool {
	stage := serviceGateStage()
	if stage == "off" || rt.validServiceToken(r) {
		return true
	}
	if stage == serviceGateShadow {
		slog.Default().Warn(serviceGateLogMsg, "route", r.Pattern, "remote", r.RemoteAddr)
		return true
	}
	httpx.WriteError(w, http.StatusUnauthorized, "unauthorized", "service token required")
	return false
}
