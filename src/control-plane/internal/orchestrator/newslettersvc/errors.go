/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   errors.go                                          :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:49:14 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:49:15 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package newslettersvc

// newslettersvcErr is a const-able error type, so this package's sentinel errors are
// const declarations (see below / sibling files) rather than package vars.
type newslettersvcErr string

func (e newslettersvcErr) Error() string { return string(e) }
