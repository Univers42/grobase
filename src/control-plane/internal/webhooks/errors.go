/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   errors.go                                          :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 05:00:59 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 05:01:01 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package webhooks

// webhooksErr is a const-able error type, so this package's sentinel errors are
// const declarations (see below / sibling files) rather than package vars.
type webhooksErr string

func (e webhooksErr) Error() string { return string(e) }
