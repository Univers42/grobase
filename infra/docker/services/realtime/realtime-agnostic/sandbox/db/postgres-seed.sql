# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    postgres-seed.sql                                  :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/05/18 21:19:15 by dlesieur          #+#    #+#              #
#    Updated: 2026/05/18 21:19:15 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

-- =============================================================================
-- SyncSpace: Seed Data
-- =============================================================================
-- Uses variables to avoid literal duplication (SonarCloud S1192).

DO $seed$
DECLARE
  -- Users
  u_alice  CONSTANT text := 'user-alice';
  u_bob    CONSTANT text := 'user-bob';
  u_carol  CONSTANT text := 'user-carol';
  -- Workspace / Board
  ws       CONSTANT text := 'ws-main';
  brd      CONSTANT text := 'board-roadmap';
  -- Lists
  l_back   CONSTANT text := 'list-backlog';
  l_wip    CONSTANT text := 'list-in-progress';
  l_rev    CONSTANT text := 'list-review';
  l_done   CONSTANT text := 'list-done';
  -- Colors
  c_red    CONSTANT text := '#ef4444';
  c_green  CONSTANT text := '#22c55e';
  c_blue   CONSTANT text := '#3b82f6';
BEGIN

-- ─── Users ──────────────────────────────────────────────────────────────
INSERT INTO users (id, username, email, avatar_url, color) VALUES
  (u_alice, 'alice', 'alice@syncspace.dev', NULL, c_red),
  (u_bob,   'bob',   'bob@syncspace.dev',   NULL, c_blue),
  (u_carol, 'carol', 'carol@syncspace.dev', NULL, c_green)
ON CONFLICT DO NOTHING;

-- ─── Workspace ──────────────────────────────────────────────────────────
INSERT INTO workspaces (id, name, owner_id) VALUES
  (ws, 'SyncSpace Demo', u_alice)
ON CONFLICT DO NOTHING;

-- ─── Board: Product Roadmap ─────────────────────────────────────────────
INSERT INTO boards (id, workspace_id, name, description, bg_color) VALUES
  (brd, ws, 'Product Roadmap', 'Q2 2026 feature planning', '#1e1b4b')
ON CONFLICT DO NOTHING;

INSERT INTO board_members (board_id, user_id, role) VALUES
  (brd, u_alice, 'admin'),
  (brd, u_bob,   'member'),
  (brd, u_carol, 'member')
ON CONFLICT DO NOTHING;

-- ─── Lists ──────────────────────────────────────────────────────────────
INSERT INTO lists (id, board_id, title, position) VALUES
  (l_back, brd, 'Backlog',      0),
  (l_wip,  brd, 'In Progress',  1),
  (l_rev,  brd, 'In Review',    2),
  (l_done, brd, 'Done',         3)
ON CONFLICT DO NOTHING;

-- ─── Cards ──────────────────────────────────────────────────────────────
INSERT INTO cards (id, list_id, board_id, title, description, position, assignee_id, label_color, created_by) VALUES
  ('card-1', l_back, brd, 'WebSocket reconnect with replay',
   'Implement automatic reconnection with event replay from last timestamp',
   0, u_alice, c_red, u_alice),

  ('card-2', l_back, brd, 'Add MySQL adapter',
   'Implement DatabaseAdapter for MySQL using mysql2',
   1, NULL, '#f97316', u_bob),

  ('card-3', l_back, brd, 'Rate limiting per subscription',
   'Add configurable rate limits to prevent event flooding',
   2, u_carol, '#eab308', u_carol),

  ('card-4', l_wip, brd, 'Live cursor overlays',
   'Show other users'' cursor positions on the board in real-time',
   0, u_bob, c_blue, u_alice),

  ('card-5', l_wip, brd, 'Chat message reactions',
   'Allow emoji reactions on chat messages stored in MongoDB',
   1, u_carol, '#8b5cf6', u_bob),

  ('card-6', l_rev, brd, 'Presence indicators',
   'Show online/offline status of board members',
   0, u_alice, c_green, u_carol),

  ('card-7', l_done, brd, 'PostgreSQL CDC integration',
   'LISTEN/NOTIFY based change data capture working end-to-end',
   0, u_alice, c_green, u_alice),

  ('card-8', l_done, brd, 'MongoDB change streams',
   'Change streams integration with event publishing',
   1, u_bob, c_green, u_bob)
ON CONFLICT DO NOTHING;

-- ─── Chat Channels ──────────────────────────────────────────────────────
INSERT INTO channels (id, board_id, name) VALUES
  ('ch-general', brd, 'general'),
  ('ch-random',  brd, 'random')
ON CONFLICT DO NOTHING;

END;
$seed$;
