/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   mongo-seed.js                                      :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:15 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:15 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

// =============================================================================
// SyncSpace: MongoDB Seed Data
// Chat messages, reactions — the schema-flexible parts
// =============================================================================

// Wait for replica set to be ready
sleep(2000);

db = db.getSiblingDB("syncspace");

// ─── Chat messages ──────────────────────────────────────────────────────
db.chat_messages.drop();
db.chat_messages.insertMany([
  {
    _id: "msg-1",
    channelId: "ch-general",
    boardId: "board-roadmap",
    userId: "user-alice",
    username: "alice",
    content: "Hey team! The realtime engine is looking great. Anyone tested the MongoDB adapter yet?",
    reactions: [{ emoji: "🚀", users: ["user-bob"] }],
    createdAt: new Date(Date.now() - 3600000),
  },
  {
    _id: "msg-2",
    channelId: "ch-general",
    boardId: "board-roadmap",
    userId: "user-bob",
    username: "bob",
    content: "Yes! Change streams are working perfectly. Events come through in <50ms.",
    reactions: [{ emoji: "🎉", users: ["user-alice", "user-carol"] }],
    createdAt: new Date(Date.now() - 3500000),
  },
  {
    _id: "msg-3",
    channelId: "ch-general",
    boardId: "board-roadmap",
    userId: "user-carol",
    username: "carol",
    content: "The debug panel is super useful for comparing adapters. Can confirm both PG and Mongo produce identical behavior.",
    reactions: [],
    createdAt: new Date(Date.now() - 3400000),
  },
  {
    _id: "msg-4",
    channelId: "ch-random",
    boardId: "board-roadmap",
    userId: "user-bob",
    username: "bob",
    content: "Who else thinks we should add a SQLite adapter for local dev?",
    reactions: [{ emoji: "👍", users: ["user-alice", "user-carol"] }],
    createdAt: new Date(Date.now() - 1800000),
  },
  {
    _id: "msg-5",
    channelId: "ch-random",
    boardId: "board-roadmap",
    userId: "user-alice",
    username: "alice",
    content: "Absolutely. Zero-config local dev would be a huge DX win.",
    reactions: [],
    createdAt: new Date(Date.now() - 1700000),
  }
]);

db.chat_messages.createIndex({ channelId: 1, createdAt: 1 });
db.chat_messages.createIndex({ boardId: 1 });

// ─── Presence tracking ──────────────────────────────────────────────────
db.presence.drop();
db.presence.createIndex({ channel: 1, userId: 1 }, { unique: true });
db.presence.createIndex({ lastSeen: 1 }, { expireAfterSeconds: 300 });

print("✅ MongoDB seeded successfully");
