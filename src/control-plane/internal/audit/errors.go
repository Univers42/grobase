/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   errors.go                                          :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:39:29 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:39:30 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package audit

// auditErr is a const-able error type, so this package's sentinel errors are
// const declarations (see below / sibling files) rather than package vars.
type auditErr string

func (e auditErr) Error() string { return string(e) }
