/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   util.rs                                            :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:15 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:15 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

use realtime_core::{OverflowPolicy, ServerMessage, SubConfig, SubOptions};
use tokio::sync::mpsc;

pub(super) fn parse_sub_config(options: Option<SubOptions>) -> SubConfig {
    options
        .map(|o| SubConfig {
            overflow: match o.overflow.as_deref() {
                Some("drop_oldest") => OverflowPolicy::DropOldest,
                Some("disconnect") => OverflowPolicy::Disconnect,
                _ => OverflowPolicy::DropNewest,
            },
            rate_limit: o.rate_limit,
            resume_from: o.resume_from,
        })
        .unwrap_or_default()
}

pub(super) async fn send_ctrl(ctrl_tx: &mpsc::Sender<String>, msg: &ServerMessage) {
    if let Ok(json) = serde_json::to_string(msg) {
        let _ = ctrl_tx.send(json).await;
    }
}
