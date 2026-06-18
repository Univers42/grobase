/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   bus.rs                                             :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:15 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:15 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! Event bus configuration.

use serde::{Deserialize, Serialize};

/// Event bus backend selection.
///
/// `InProcess` is the default single-node bus. `Irc` bridges the gateway to an
/// external RFC 2812 IRC server (e.g. `ircserv`): topics in the configured
/// namespace map to IRC channels.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum EventBusConfig {
    #[serde(rename = "inprocess")]
    InProcess {
        #[serde(default = "default_bus_capacity")]
        capacity: usize,
    },
    #[serde(rename = "irc")]
    Irc {
        /// IRC server host.
        host: String,
        /// IRC server port.
        #[serde(default = "default_irc_port")]
        port: u16,
        /// Server password (`PASS`); empty to skip.
        #[serde(default)]
        password: String,
        /// Service nickname for the relay connection.
        #[serde(default = "default_irc_nick")]
        nick: String,
        /// IRC username.
        #[serde(default = "default_irc_user")]
        user: String,
        /// IRC realname.
        #[serde(default = "default_irc_realname")]
        realname: String,
        /// Channels to auto-join on connect.
        #[serde(default)]
        channels: Vec<String>,
        /// Gateway topic namespace bridged to IRC.
        #[serde(default = "default_irc_namespace")]
        namespace: String,
        /// Inbound broadcast channel capacity.
        #[serde(default = "default_bus_capacity")]
        capacity: usize,
    },
}

impl Default for EventBusConfig {
    fn default() -> Self {
        Self::InProcess {
            capacity: default_bus_capacity(),
        }
    }
}

const fn default_bus_capacity() -> usize {
    65536
}

const fn default_irc_port() -> u16 {
    6667
}

fn default_irc_nick() -> String {
    "platform-gw".to_string()
}

fn default_irc_user() -> String {
    "platform".to_string()
}

fn default_irc_realname() -> String {
    "Realtime Gateway".to_string()
}

fn default_irc_namespace() -> String {
    "chat".to_string()
}
