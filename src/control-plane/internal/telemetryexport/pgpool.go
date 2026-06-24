/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   pgpool.go                                          :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:57:50 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:57:52 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package telemetryexport

import "context"

func (p pgPool) AdminQuery(ctx context.Context, sql string, args ...any) (rows, error) {
	r, err := p.db.AdminQuery(ctx, sql, args...)
	if err != nil {
		return nil, err
	}
	return pgxRows{r}, nil
}

func (p pgPool) AdminExec(ctx context.Context, sql string, args ...any) error {
	return p.db.AdminExec(ctx, sql, args...)
}
