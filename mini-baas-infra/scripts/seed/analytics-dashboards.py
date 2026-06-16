#!/usr/bin/env python3
"""Emit SQL for the osionos 'Analytics' workspace pages (stdout → psql).

Usage: analytics-dashboards.py <workspace_id> <owner_id> <pg_db_id> <mysql_db_id> <mongo_db_id>

A curated analytics tree over the live mounts: every page opens a live table
directly on one of the preset CHART/DASHBOARD views (block.viewId →
DatabaseBlock initialViewId), so the seeded account lands on real-data
dashboards — the notion-model Analytics Hub (drag-arranged widgets), the
ECharts family (funnel/heatmap/gauge/waterfall/treemap/sunburst) and the
conditionally-colored revenue chart. Page ids are uuid5 (idempotent reruns);
mount ids are re-resolved every run (ON CONFLICT DO UPDATE refreshes them).
"""
import base64
import json
import sys
import uuid

WS, OWNER, PG_ID, MY_ID, MG_ID = sys.argv[1:6]
NS = uuid.UUID("6ba7b811-9dad-11d1-80b4-00c04fd430c8")  # uuid5 URL namespace

# (slug, title, icon, blurb, table-db-id, table, preset view suffix or None)
PAGES = [
    ("hub", "Revenue Hub", "📊",
     "The notion-model dashboard: widgets are real views over 25k PostgreSQL "
     "orders — drag the grip to rearrange, resize with the dividers, filter "
     "all widgets at once.",
     PG_ID, "orders", "commerce-hub"),
    ("revenue", "Revenue by Status", "💰",
     "Server-truth aggregate over every order row, with conditional colors "
     "(delivered green, cancelled red, pending amber).",
     PG_ID, "orders", "commerce-revenue"),
    ("funnel", "Order Funnel", "🫙",
     "The order pipeline as an ECharts funnel — one of 50+ chart presets in "
     "the gallery (Edit view → Browse all chart types).",
     PG_ID, "orders", "commerce-funnel"),
    ("mix", "Status × Ship Heatmap", "🌡️",
     "Two-dimensional density: status columns × ship-method rows.",
     PG_ID, "orders", "commerce-mix"),
    ("gauge", "Revenue Gauge", "⏲️",
     "Total revenue as a progress gauge.",
     PG_ID, "orders", "commerce-gauge"),
    ("waterfall", "Revenue Waterfall", "🪜",
     "Revenue contribution per status, with the running total.",
     PG_ID, "orders", "commerce-waterfall"),
    ("treemap", "Catalog Treemap", "🗺️",
     "Price mass by product category (try Sunburst from the view tabs).",
     PG_ID, "products", "commerce-treemap"),
    ("workload", "Ops Workload", "🏗️",
     "MySQL tasks: estimated hours by status.",
     MY_ID, "tasks", "ops-workload"),
    ("activity", "Activity Stream", "📈",
     "30k MongoDB events — switch view tabs for the feeds and charts.",
     MG_ID, "events", None),
]


def b64(payload) -> str:
    return base64.b64encode(json.dumps(payload).encode()).decode()


def q(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def page_sql(page_id, parent, title, icon, surface, content) -> str:
    return (
        "INSERT INTO public.osionos_pages"
        " (id, workspace_id, parent_page_id, owner_id, title, icon, surface,"
        " visibility, collaborators, properties, content, created_at, updated_at) VALUES ("
        f"{q(page_id)}, {q(WS)}, {('NULL' if parent is None else q(parent))}, {q(OWNER)},"
        f" {q(title)}, {q(icon)}, {q(surface)}, 'private', '[]'::jsonb,"
        f" convert_from(decode('{b64([])}','base64'),'utf8')::jsonb,"
        f" convert_from(decode('{b64(content)}','base64'),'utf8')::jsonb, now(), now())"
        " ON CONFLICT (id) DO UPDATE SET title = EXCLUDED.title, icon = EXCLUDED.icon,"
        " content = EXCLUDED.content, parent_page_id = EXCLUDED.parent_page_id,"
        " updated_at = now();"
    )


def main() -> None:
    folder_id = str(uuid.uuid5(NS, "analytics:folder"))
    statements = ["BEGIN;"]
    statements.append(page_sql(folder_id, None, "Analytics", "📊", "folder", []))
    intro_id = str(uuid.uuid5(NS, "analytics:intro"))
    statements.append(page_sql(intro_id, folder_id, "Start here — real-data dashboards", "🚀", "page", [
        {"id": "blk-1", "type": "heading_1", "content": "Dashboards over live engines"},
        {"id": "blk-2", "type": "paragraph", "content":
            "Every page in this folder opens a LIVE database directly on a "
            "curated chart or dashboard view. The data is real: PostgreSQL "
            "(25k orders), MySQL (ops) and MongoDB (activity) through the "
            "mini-baas gateway."},
        {"id": "blk-3", "type": "callout", "color": "💡", "content":
            "Open any view's settings: pick another Source, browse 50+ chart "
            "types, add conditional colors, save the chart as PNG/SVG/CSV, "
            "or define server-side Automations that fire for every client."},
    ]))
    for slug, title, icon, blurb, db_id, table, view_suffix in PAGES:
        page_id = str(uuid.uuid5(NS, f"analytics:{slug}"))
        database_id = f"baas:{db_id}:{table}"
        block = {"id": "blk-2", "type": "database_full_page", "content": "",
                 "databaseId": database_id}
        if view_suffix:
            block["viewId"] = f"{database_id}#{view_suffix}"
        statements.append(page_sql(page_id, folder_id, title, icon, "page", [
            {"id": "blk-1", "type": "paragraph", "content": blurb},
            block,
        ]))
    statements.append("COMMIT;")
    print("\n".join(statements))


main()
