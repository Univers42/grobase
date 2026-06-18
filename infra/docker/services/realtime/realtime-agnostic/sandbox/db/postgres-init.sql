# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    postgres-init.sql                                  :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/05/18 21:19:15 by dlesieur          #+#    #+#              #
#    Updated: 2026/05/18 21:19:15 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

-- =============================================================================
-- SyncSpace: PostgreSQL Schema
-- Boards, lists, cards, users, membership + realtime event log
-- =============================================================================

-- ─── Realtime notification trigger ──────────────────────────────────────
CREATE OR REPLACE FUNCTION realtime_notify() RETURNS trigger AS $$
DECLARE
  payload json;
  channel_name text;
BEGIN
  channel_name := TG_ARGV[0];
  IF channel_name IS NULL THEN
    channel_name := 'realtime_events';
  END IF;

  payload = json_build_object(
    'table', TG_TABLE_NAME,
    'schema', TG_TABLE_SCHEMA,
    'operation', TG_OP,
    'data', CASE
      WHEN TG_OP = 'DELETE' THEN row_to_json(OLD)
      ELSE row_to_json(NEW)
    END,
    'old_data', CASE
      WHEN TG_OP = 'UPDATE' THEN row_to_json(OLD)
      ELSE NULL
    END
  );
  PERFORM pg_notify(channel_name, payload::text);
  RETURN COALESCE(NEW, OLD);
END;
$$ LANGUAGE plpgsql;

-- ─── Users ──────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS users (
    id          TEXT PRIMARY KEY,
    username    VARCHAR(50) UNIQUE NOT NULL,
    email       VARCHAR(255) UNIQUE NOT NULL,
    avatar_url  VARCHAR(500),
    color       VARCHAR(7) NOT NULL DEFAULT '#6366f1',
    created_at  TIMESTAMPTZ DEFAULT NOW()
);

-- ─── Workspaces ─────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS workspaces (
    id          TEXT PRIMARY KEY,
    name        VARCHAR(200) NOT NULL,
    owner_id    TEXT REFERENCES users(id),
    created_at  TIMESTAMPTZ DEFAULT NOW()
);

-- ─── Boards ─────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS boards (
    id          TEXT PRIMARY KEY,
    workspace_id TEXT REFERENCES workspaces(id),
    name        VARCHAR(200) NOT NULL,
    description TEXT,
    bg_color    VARCHAR(7) DEFAULT '#1a1d27',
    created_at  TIMESTAMPTZ DEFAULT NOW(),
    updated_at  TIMESTAMPTZ DEFAULT NOW()
);

-- ─── Board membership ───────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS board_members (
    board_id    TEXT REFERENCES boards(id) ON DELETE CASCADE,
    user_id     TEXT REFERENCES users(id) ON DELETE CASCADE,
    role        VARCHAR(20) DEFAULT 'member',
    joined_at   TIMESTAMPTZ DEFAULT NOW(),
    PRIMARY KEY (board_id, user_id)
);

-- ─── Lists (columns) ───────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS lists (
    id          TEXT PRIMARY KEY,
    board_id    TEXT REFERENCES boards(id) ON DELETE CASCADE,
    title       VARCHAR(200) NOT NULL,
    position    INTEGER NOT NULL DEFAULT 0,
    created_at  TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_lists_board ON lists(board_id, position);

-- ─── Cards ──────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS cards (
    id          TEXT PRIMARY KEY,
    list_id     TEXT REFERENCES lists(id) ON DELETE CASCADE,
    board_id    TEXT REFERENCES boards(id) ON DELETE CASCADE,
    title       VARCHAR(500) NOT NULL,
    description TEXT,
    position    INTEGER NOT NULL DEFAULT 0,
    assignee_id TEXT REFERENCES users(id),
    label_color VARCHAR(7),
    due_date    TIMESTAMPTZ,
    created_by  TEXT REFERENCES users(id),
    created_at  TIMESTAMPTZ DEFAULT NOW(),
    updated_at  TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_cards_list ON cards(list_id, position);
CREATE INDEX IF NOT EXISTS idx_cards_board ON cards(board_id);

-- ─── Channels (for chat) ───────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS channels (
    id          TEXT PRIMARY KEY,
    board_id    TEXT REFERENCES boards(id) ON DELETE CASCADE,
    name        VARCHAR(100) NOT NULL,
    created_at  TIMESTAMPTZ DEFAULT NOW()
);

-- ─── Realtime event log ────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS realtime_events (
    id          TEXT PRIMARY KEY,
    channel     TEXT NOT NULL,
    event       VARCHAR(100) NOT NULL,
    payload     JSONB NOT NULL DEFAULT '{}',
    actor_id    TEXT,
    timestamp   BIGINT NOT NULL,
    created_at  TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_rt_events_ch_ts ON realtime_events(channel, timestamp);

-- ─── Realtime presence ─────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS realtime_presence (
    channel     TEXT NOT NULL,
    user_id     TEXT NOT NULL,
    online      BOOLEAN DEFAULT false,
    last_seen   BIGINT NOT NULL,
    PRIMARY KEY (channel, user_id)
);

-- ─── Triggers ───────────────────────────────────────────────────────────
-- Reuse a single channel name variable to avoid literal duplication (S1192).
DO $trigger_setup$
DECLARE
  ch CONSTANT text := 'realtime_events';
BEGIN
  EXECUTE format(
    'CREATE TRIGGER boards_realtime AFTER INSERT OR UPDATE OR DELETE ON boards FOR EACH ROW EXECUTE FUNCTION realtime_notify(%L)', ch);
  EXECUTE format(
    'CREATE TRIGGER lists_realtime AFTER INSERT OR UPDATE OR DELETE ON lists FOR EACH ROW EXECUTE FUNCTION realtime_notify(%L)', ch);
  EXECUTE format(
    'CREATE TRIGGER cards_realtime AFTER INSERT OR UPDATE OR DELETE ON cards FOR EACH ROW EXECUTE FUNCTION realtime_notify(%L)', ch);
  EXECUTE format(
    'CREATE TRIGGER channels_realtime AFTER INSERT OR UPDATE OR DELETE ON channels FOR EACH ROW EXECUTE FUNCTION realtime_notify(%L)', ch);
END;
$trigger_setup$;
