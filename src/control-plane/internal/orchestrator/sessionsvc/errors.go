/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   errors.go                                          :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:50:26 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:50:27 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package sessionsvc

// sessionsvcErr is a const-able error type, so this package's sentinel errors are
// const declarations (see below / sibling files) rather than package vars.
type sessionsvcErr string

func (e sessionsvcErr) Error() string { return string(e) }
