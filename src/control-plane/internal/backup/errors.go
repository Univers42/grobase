/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   errors.go                                          :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:39:48 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:39:49 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package backup

// backupErr is a const-able error type, so this package's sentinel errors are
// const declarations (see below / sibling files) rather than package vars.
type backupErr string

func (e backupErr) Error() string { return string(e) }
