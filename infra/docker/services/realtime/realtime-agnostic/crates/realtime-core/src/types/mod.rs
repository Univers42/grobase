/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   mod.rs                                             :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:15 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:15 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! Core type definitions for the Realtime-Agnostic event routing engine.
//!
//! This module defines all fundamental types: newtypes for type safety,
//! the canonical [`EventEnvelope`], topic patterns, subscription config,
//! authentication claims, and dispatch types.

mod auth_claims;
mod dispatch;
mod envelope;
mod event_id;
mod identifiers;
mod payload;
mod subscription;
mod topic_path;
mod topic_pattern;

pub use auth_claims::*;
pub use dispatch::*;
pub use envelope::*;
pub use event_id::*;
pub use identifiers::*;
pub use payload::*;
pub use subscription::*;
pub use topic_path::*;
pub use topic_pattern::*;

#[cfg(test)]
mod tests;
