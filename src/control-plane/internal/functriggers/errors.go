/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   errors.go                                          :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:44:33 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:44:35 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package functriggers

// functriggersErr is a const-able error type, so this package's sentinel errors are
// const declarations (see below / sibling files) rather than package vars.
type functriggersErr string

func (e functriggersErr) Error() string { return string(e) }
