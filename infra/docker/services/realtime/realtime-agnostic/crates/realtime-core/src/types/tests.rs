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

use super::*;
use bytes::Bytes;
use std::collections::HashMap;

#[test]
fn event_id_generation() {
    let id1 = EventId::new();
    let id2 = EventId::new();
    assert_ne!(id1, id2);
}

#[test]
fn topic_path_parts() {
    let topic = TopicPath::new("orders/created");
    assert_eq!(topic.namespace(), "orders");
    assert_eq!(topic.event_type_part(), "created");
}

#[test]
fn topic_pattern_exact() {
    let pattern = TopicPattern::Exact(TopicPath::new("orders/created"));
    assert!(pattern.matches(&TopicPath::new("orders/created")));
    assert!(!pattern.matches(&TopicPath::new("orders/updated")));
}

#[test]
fn topic_pattern_prefix() {
    let pattern = TopicPattern::Prefix(smol_str::SmolStr::new("orders/"));
    assert!(pattern.matches(&TopicPath::new("orders/created")));
    assert!(pattern.matches(&TopicPath::new("orders/deleted")));
    assert!(!pattern.matches(&TopicPath::new("users/created")));
}

#[test]
fn topic_pattern_glob() {
    let p1 = TopicPattern::Glob(smol_str::SmolStr::new("orders/*"));
    assert!(p1.matches(&TopicPath::new("orders/created")));
    assert!(!p1.matches(&TopicPath::new("users/anything")));
    // Single * must NOT match multiple segments
    assert!(!p1.matches(&TopicPath::new("orders/created/details")));

    let p2 = TopicPattern::Glob(smol_str::SmolStr::new("*/created"));
    assert!(p2.matches(&TopicPath::new("orders/created")));
    assert!(!p2.matches(&TopicPath::new("users/deleted")));
    assert!(!p2.matches(&TopicPath::new("orders/123/created")));

    // Recursive wildcard ** matches any remaining segments
    let p3 = TopicPattern::Glob(smol_str::SmolStr::new("orders/**"));
    assert!(p3.matches(&TopicPath::new("orders/created")));
    assert!(p3.matches(&TopicPath::new("orders/123/items/456")));
    assert!(!p3.matches(&TopicPath::new("users/123")));
}

#[test]
fn topic_pattern_display_and_as_str() {
    let exact = TopicPattern::Exact(TopicPath::new("orders/created"));
    assert_eq!(exact.as_str(), "orders/created");
    assert_eq!(format!("{exact}"), "orders/created");

    let prefix = TopicPattern::Prefix(smol_str::SmolStr::new("orders/"));
    assert_eq!(prefix.as_str(), "orders/");
    assert_eq!(format!("{prefix}"), "orders/");

    let glob = TopicPattern::Glob(smol_str::SmolStr::new("orders/*"));
    assert_eq!(glob.as_str(), "orders/*");
    assert_eq!(format!("{glob}"), "orders/*");
}

#[test]
fn topic_pattern_parse() {
    assert!(matches!(
        TopicPattern::parse("orders/created"),
        TopicPattern::Exact(_)
    ));
    assert!(matches!(
        TopicPattern::parse("orders/"),
        TopicPattern::Prefix(_)
    ));
    assert!(matches!(
        TopicPattern::parse("orders/*"),
        TopicPattern::Glob(_)
    ));
}

#[test]
fn event_envelope_creation() {
    let payload = Bytes::from(r#"{"key":"value"}"#);
    let event = EventEnvelope::new(TopicPath::new("test/event"), "created", payload);
    assert_eq!(event.topic, TopicPath::new("test/event"));
    assert!(!event.is_payload_too_large());
}

#[test]
fn payload_too_large() {
    let payload = Bytes::from(vec![0u8; 70_000]);
    let event = EventEnvelope::new(TopicPath::new("test"), "test", payload);
    assert!(event.is_payload_too_large());
}

#[test]
fn auth_claims_subscribe() {
    let claims = AuthClaims {
        sub: "user1".to_string(),
        namespaces: vec!["orders".to_string(), "users".to_string()],
        can_publish: false,
        can_subscribe: true,
        metadata: HashMap::new(),
    };
    let allowed = TopicPattern::Exact(TopicPath::new("orders/created"));
    let denied = TopicPattern::Exact(TopicPath::new("admin/settings"));
    assert!(claims.can_subscribe_to(&allowed));
    assert!(!claims.can_subscribe_to(&denied));
}

#[test]
fn auth_claims_empty_namespaces_deny_by_default() {
    // Phase 5 security baseline: a namespace-less claim grants NO access.
    let empty = AuthClaims {
        sub: "u".to_string(),
        namespaces: vec![],
        can_publish: true,
        can_subscribe: true,
        metadata: HashMap::new(),
    };
    assert!(
        !empty.can_subscribe_to(&TopicPattern::Exact(TopicPath::new("orders/created"))),
        "empty namespaces must deny subscribe"
    );
    assert!(
        !empty.can_publish_to(&TopicPath::new("orders/created")),
        "empty namespaces must deny publish"
    );
    // All-access remains expressible — but only EXPLICITLY, via "*".
    let wild = AuthClaims {
        sub: "u".to_string(),
        namespaces: vec!["*".to_string()],
        can_publish: true,
        can_subscribe: true,
        metadata: HashMap::new(),
    };
    assert!(wild.can_subscribe_to(&TopicPattern::Exact(TopicPath::new("anything/x"))));
    assert!(wild.can_publish_to(&TopicPath::new("anything/x")));
}

#[test]
fn protected_namespace_excludes_wildcard() {
    // A `"*"` wildcard reaches everything EXCEPT a protected-prefix namespace,
    // which needs an exact grant — so a wildcard token cannot read a `collab:`
    // space it was not explicitly added to.
    let protected = vec!["collab:".to_string()];
    let collab = TopicPattern::Exact(TopicPath::new("collab:abc"));
    let chat = TopicPattern::Exact(TopicPath::new("chat:xyz"));

    let wild = AuthClaims {
        sub: "u".to_string(),
        namespaces: vec!["*".to_string()],
        can_publish: true,
        can_subscribe: true,
        metadata: HashMap::new(),
    };
    assert!(
        wild.can_subscribe_to_scoped(&chat, &protected),
        "wildcard still covers unprotected namespaces"
    );
    assert!(
        !wild.can_subscribe_to_scoped(&collab, &protected),
        "wildcard must NOT cover a protected namespace"
    );
    assert!(
        wild.can_subscribe_to_scoped(&collab, &[]),
        "empty protected list is byte-parity (wildcard covers everything)"
    );
    assert!(
        !wild.can_publish_to_scoped(&TopicPath::new("collab:abc"), &protected),
        "publish is protected the same way"
    );

    let member = AuthClaims {
        sub: "u".to_string(),
        namespaces: vec!["collab:abc".to_string()],
        can_publish: true,
        can_subscribe: true,
        metadata: HashMap::new(),
    };
    assert!(
        member.can_subscribe_to_scoped(&collab, &protected),
        "an exact grant still reaches the protected space"
    );
    assert!(
        !member.can_subscribe_to_scoped(
            &TopicPattern::Exact(TopicPath::new("collab:other")),
            &protected
        ),
        "but only the granted space, not a sibling"
    );
}

fn scoped_claims(namespaces: &[&str]) -> AuthClaims {
    AuthClaims {
        sub: "u".to_string(),
        namespaces: namespaces.iter().copied().map(String::from).collect(),
        can_publish: true,
        can_subscribe: true,
        metadata: HashMap::new(),
    }
}

#[test]
fn wildcard_namespace_pattern_refused_under_protection() {
    // A pattern whose first segment is a wildcard spans EVERY namespace, so the
    // gateway cannot enforce the protected prefixes on it topic by topic: with
    // protection configured it is refused for everyone.
    let protected = vec!["pg".to_string(), "collab:".to_string()];
    let star = scoped_claims(&["*"]);
    for (pattern, allowed) in [
        ("**", false),
        ("*/users", false),
        ("*/**", false),
        ("*", false),
        ("chat:a/**", true),
        ("chat:a", true),
        ("pg/**", false),
        ("pg/users", false),
    ] {
        assert_eq!(
            star.can_subscribe_to_scoped(&TopicPattern::parse(pattern), &protected),
            allowed,
            "{pattern} under protected {protected:?}"
        );
    }
}

#[test]
fn wildcard_namespace_pattern_allowed_when_nothing_protected() {
    // Nothing protected — an empty list, or one holding only empty entries —
    // keeps today's behaviour for the all-access claim.
    let star = scoped_claims(&["*"]);
    for protected in [Vec::new(), vec![String::new()]] {
        for pattern in ["**", "*", "*/x"] {
            assert!(
                star.can_subscribe_to_scoped(&TopicPattern::parse(pattern), &protected),
                "{pattern} stays covered by the all-access claim (protected = {protected:?})"
            );
        }
    }
}

#[test]
fn wildcard_namespace_pattern_never_granted_by_exact_namespace() {
    // An exact grant of `pg` still covers `pg/**` and `pg/users`, but never `**`:
    // a wildcard-namespace pattern spans namespaces nobody granted.
    let protected = vec!["pg".to_string()];
    let pg_only = scoped_claims(&["pg"]);
    for (pattern, allowed) in [("pg/**", true), ("pg/users", true), ("**", false)] {
        assert_eq!(
            pg_only.can_subscribe_to_scoped(&TopicPattern::parse(pattern), &protected),
            allowed,
            "{pattern} for an exact grant of `pg` under protected {protected:?}"
        );
    }

    let chat_only = scoped_claims(&["chat:a"]);
    assert!(
        !chat_only.can_subscribe_to(&TopicPattern::parse("**")),
        "without a \"*\" claim, no wildcard-namespace pattern is admitted"
    );
}

#[test]
fn wildcard_namespace_pattern_obeys_deny_by_default() {
    // The deny-by-default guards run before any pattern is examined.
    let denied = [
        AuthClaims {
            can_subscribe: false,
            ..scoped_claims(&["*"])
        },
        scoped_claims(&[]),
    ];
    for claims in &denied {
        for pattern in ["**", "orders/created"] {
            let topic = TopicPattern::parse(pattern);
            assert!(
                !claims.can_subscribe_to(&topic) && !claims.can_subscribe_to_scoped(&topic, &[]),
                "can_subscribe=false or empty namespaces must refuse {pattern}"
            );
        }
    }
}
