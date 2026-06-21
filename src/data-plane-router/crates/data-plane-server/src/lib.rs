/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   lib.rs                                             :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:33:02 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:33:03 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

// Pre-existing pedantic-lint debt in the A2/A3 data-plane modules (automations,
// outbox, ratelimit, routes), surfaced the first time `clippy -D warnings` ran
// across the full workspace post-cutover (the image build only runs
// `cargo build`). These are domain-shaped — many-arg execute paths, a large
// rate-limiter enum, a large error Response, doc lists — so they're allowed
// crate-wide here rather than refactored under a release cut; tracked for a
// follow-up structural pass.
#![allow(clippy::too_many_arguments)]
#![allow(clippy::large_enum_variant)]
#![allow(clippy::result_large_err)]
#![allow(clippy::doc_lazy_continuation)]

pub mod abac;
pub mod auth;
#[cfg(feature = "control-pg")]
pub mod automations;
pub mod config;
pub mod graph;
pub mod metrics;
#[cfg(feature = "nano")]
pub mod nano;
#[cfg(feature = "one")]
pub mod one;
#[cfg(feature = "one")]
pub mod one_admin;
#[cfg(feature = "one")]
pub mod one_email;
#[cfg(feature = "one")]
pub mod one_files;
#[cfg(feature = "one")]
pub mod one_oauth;
#[cfg(feature = "one")]
pub mod one_totp;
#[cfg(feature = "control-pg")]
pub mod outbox;
pub mod quota;
pub mod ratelimit;
pub mod routes;
pub mod server;
pub mod signal;
pub mod usage;
