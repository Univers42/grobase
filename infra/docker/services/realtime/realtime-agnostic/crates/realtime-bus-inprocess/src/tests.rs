/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   tests.rs                                           :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:15 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:15 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

#![allow(clippy::unwrap_used)]

use crate::InProcessBus;
use bytes::Bytes;
use realtime_core::{EventBus, TopicPath};

#[tokio::test]
async fn test_publish_and_subscribe() {
    let bus = InProcessBus::new(1024);

    let publisher = bus.publisher().await.unwrap();
    let mut subscriber = bus.subscriber("*").await.unwrap();

    let event = realtime_core::EventEnvelope::new(
        TopicPath::new("test/event"),
        "created",
        Bytes::from(r#"{"key":"value"}"#),
    );

    let receipt = publisher.publish("test/event", &event).await.unwrap();
    assert!(receipt.delivered_to_bus);

    let received = subscriber.next_event().await.unwrap();
    assert_eq!(received.topic, event.topic);
    assert_eq!(received.event_type, "created");
}

#[tokio::test]
async fn test_multiple_subscribers() {
    let bus = InProcessBus::new(1024);

    let publisher = bus.publisher().await.unwrap();
    let mut sub1 = bus.subscriber("*").await.unwrap();
    let mut sub2 = bus.subscriber("*").await.unwrap();

    let event =
        realtime_core::EventEnvelope::new(TopicPath::new("test"), "test", Bytes::from("{}"));

    publisher.publish("test", &event).await.unwrap();

    let r1 = sub1.next_event().await.unwrap();
    let r2 = sub2.next_event().await.unwrap();

    assert_eq!(r1.event_id, r2.event_id);
}

#[tokio::test]
async fn test_batch_publish() {
    let bus = InProcessBus::new(1024);

    let publisher = bus.publisher().await.unwrap();
    let mut subscriber = bus.subscriber("*").await.unwrap();

    let events: Vec<(String, realtime_core::EventEnvelope)> = (0..5)
        .map(|i| {
            let e = realtime_core::EventEnvelope::new(
                TopicPath::new(&format!("test/{i}")),
                "created",
                Bytes::from("{}"),
            );
            (format!("test/{i}"), e)
        })
        .collect();

    let receipts = publisher.publish_batch(&events).await.unwrap();
    assert_eq!(receipts.len(), 5);

    for _ in 0..5 {
        let received = subscriber.next_event().await.unwrap();
        assert_eq!(received.event_type, "created");
    }
}

#[tokio::test]
async fn test_health_check() {
    let bus = InProcessBus::new(1024);
    assert!(bus.health_check().await.is_ok());
}
