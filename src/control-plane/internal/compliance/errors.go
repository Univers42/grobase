/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   errors.go                                          :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:41:51 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:41:52 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package compliance

// complianceErr is a const-able error type, so this package's sentinel errors are
// const declarations (see below / sibling files) rather than package vars.
type complianceErr string

func (e complianceErr) Error() string { return string(e) }
