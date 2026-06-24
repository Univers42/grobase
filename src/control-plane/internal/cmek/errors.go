/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   errors.go                                          :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:41:26 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:41:28 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package cmek

// cmekErr is the package's const error type, so every sentinel is a typed
// constant (no package-level var) while preserving errors.Is + %w wrapping.
type cmekErr string

func (e cmekErr) Error() string { return string(e) }
