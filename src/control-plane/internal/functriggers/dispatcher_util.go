/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   dispatcher_util.go                                 :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:44:28 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:44:30 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package functriggers

func stringFromPayload(p map[string]any, key string) string {
	if p == nil {
		return ""
	}
	if v, ok := p[key].(string); ok {
		return v
	}
	return ""
}
