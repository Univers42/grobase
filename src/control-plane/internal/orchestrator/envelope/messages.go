/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   messages.go                                        :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:48:21 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:48:22 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package envelope

import "net/http"

// methodMessage reproduces METHOD_MESSAGES from the Node interceptor exactly,
// as a nested switch (no package-level map). It returns the per-method,
// per-status message and an ok flag with the SAME comma-ok semantics the old
// map lookup had: an unknown method OR an unknown status for a known method
// yields ("", false) — so message() falls back to "Operation successful".
// perf: nested switch over a map double-lookup — response path, called per-request.
func methodMessage(method string, status int) (string, bool) {
	switch method {
	case http.MethodGet:
		return getMessage(status)
	case http.MethodPost:
		return postMessage(status)
	case http.MethodPut, http.MethodPatch:
		return putPatchMessage(status)
	case http.MethodDelete:
		return deleteMessage(status)
	}
	return "", false
}

func getMessage(status int) (string, bool) {
	if status == 200 {
		return "Data retrieved successfully", true
	}
	return "", false
}

func postMessage(status int) (string, bool) {
	switch status {
	case 201:
		return "Resource created successfully", true
	case 200:
		return "Operation successful", true
	}
	return "", false
}

func putPatchMessage(status int) (string, bool) {
	if status == 200 {
		return "Resource updated successfully", true
	}
	return "", false
}

func deleteMessage(status int) (string, bool) {
	if status == 200 {
		return "Resource deleted successfully", true
	}
	return "", false
}
