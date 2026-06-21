/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   store_scan.go                                      :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:52:33 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:52:35 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package passkeys

import (
	"strings"

	"github.com/jackc/pgx/v5"
)

func scanCredentials(rows pgx.Rows) ([]storedCredential, error) {
	defer rows.Close()
	out := make([]storedCredential, 0)
	for rows.Next() {
		var c storedCredential
		var signCount int64
		if err := rows.Scan(&c.ID, &c.TenantID, &c.UserID, &c.Name,
			&c.CredentialID, &c.PublicKey, &signCount, &c.AAGUID, &c.Transports); err != nil {
			return nil, err
		}
		c.SignCount = uint32(signCount)
		out = append(out, c)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return out, nil
}

// transportsCSV joins protocol transport hints for storage.
func transportsCSV(ts []string) string { return strings.Join(ts, ",") }
