/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   error.rs                                           :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:27:29 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:27:31 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! Backend-error classification: map tiberius server messages to the right
//! `DataPlaneError` (constraint violations → client 409, everything else 5xx).

use super::*;

pub(super) fn backend<E: std::fmt::Display>(e: E) -> DataPlaneError {
    let msg = e.to_string();
    let lower = msg.to_ascii_lowercase();
    if lower.contains("unique")
        || lower.contains("duplicate key")
        || lower.contains("primary key")
        || lower.contains("foreign key")
        || lower.contains("cannot insert the value null")
        || lower.contains("constraint")
    {
        DataPlaneError::Conflict {
            message: format!("mssql constraint: {msg}"),
        }
    } else {
        DataPlaneError::Backend {
            message: format!("mssql backend: {msg}"),
        }
    }
}
