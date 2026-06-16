#!/usr/bin/env python3
"""Emit SQL for the osionos 'Live Databases' workspace pages (stdout → psql).

Usage: live-demo-pages.py <workspace_id> <owner_id> <pg_db_id> <mysql_db_id> <mongo_db_id>

One folder + one page per mounted table; each page holds a single
`database_full_page` block whose databaseId is `baas:<dbId>:<table>` — the id
namespace DatabaseBlock.tsx dispatches to the LiveMountAdapter. Page uuids are
uuid5 of the mount-name+table (stable across runs), while the block's mount id
is re-resolved every run, so ON CONFLICT DO UPDATE refreshes the content if
the mounts were ever re-registered under new ids.
"""
import base64
import json
import sys
import uuid

WS, OWNER, PG_ID, MY_ID, MG_ID = sys.argv[1:6]
NS = uuid.UUID("6ba7b811-9dad-11d1-80b4-00c04fd430c8")  # uuid5 URL namespace

TABLES = [
    ("pg-commerce", PG_ID, "postgresql", "🐘", [
        ("orders", "🧾", "25k orders with status enum, ship method, FK to customers/employees."),
        ("customers", "👥", "5k customers across four regions — edit a cell, it lands in Postgres."),
        ("products", "📦", "1.2k products with category enum and pricing."),
        ("order_items", "🧮", "75k order lines (FK to orders + products)."),
        ("inventory", "🏬", "Stock per warehouse enum, reorder levels."),
        ("employees", "🧑‍💼", "Org with a self-referencing manager FK."),
        ("edges", "🕸️", "Cross-engine relations: tickets→orders, reviews→products, events→customers."),
    ]),
    ("mysql-ops", MY_ID, "mysql", "🐬", [
        ("projects", "🗂️", "40 ops projects (status enum, budget)."),
        ("tasks", "✅", "2k tasks — status/priority enums make great board views."),
        ("tickets", "🎫", "3k support tickets, severity enum, order_ref pointing at pg-commerce."),
        ("time_entries", "⏱️", "6k entries with tinyint(1) → checkbox booleans."),
    ]),
    ("mongo-activity", MG_ID, "mongodb", "🍃", [
        ("events", "📈", "30k activity events — $jsonSchema validator, kind enum."),
        ("product_reviews", "⭐", "8k reviews with ratings; edits validate against the declared schema."),
        ("notes", "📝", "Ops notes with tag arrays — fully editable documents."),
    ]),
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
    folder_id = str(uuid.uuid5(NS, "live-demo:folder"))
    statements = ["BEGIN;"]
    statements.append(page_sql(folder_id, None, "Live Databases", "🔌", "folder", []))
    intro_id = str(uuid.uuid5(NS, "live-demo:intro"))
    statements.append(page_sql(intro_id, folder_id, "Start here — live data", "🚀", "page", [
        {"id": "blk-1", "type": "heading_1", "content": "Real engines, real rows"},
        {"id": "blk-2", "type": "paragraph", "content":
            "Every database under this folder is a LIVE mount: rows come from "
            "PostgreSQL, MySQL and MongoDB through the mini-baas gateway, and "
            "any cell you edit is written back to the source engine."},
        {"id": "blk-3", "type": "callout", "content":
            "Edits are optimistic with an outbox — a 409 conflict snaps the "
            "cell back to server truth. Schema changes (add/remove column) "
            "run real DDL.", "color": "💡"},
        {"id": "blk-4", "type": "paragraph", "content":
            "pg-commerce holds the storefront (orders, customers, products); "
            "mysql-ops the internal tooling (projects, tasks, tickets); "
            "mongo-activity the event stream (events, reviews, notes)."},
    ]))
    for mount_name, db_id, engine, engine_icon, tables in TABLES:
        mount_page = str(uuid.uuid5(NS, f"live-demo:{mount_name}"))
        statements.append(page_sql(
            mount_page, folder_id, mount_name, engine_icon, "folder", []))
        for table, icon, blurb in tables:
            page_id = str(uuid.uuid5(NS, f"live-demo:{mount_name}:{table}"))
            title = table.replace("_", " ").title()
            statements.append(page_sql(page_id, mount_page, title, icon, "page", [
                {"id": "blk-1", "type": "paragraph",
                 "content": f"{blurb} (engine: {engine}, mount {mount_name})"},
                {"id": "blk-2", "type": "database_full_page", "content": "",
                 "databaseId": f"baas:{db_id}:{table}"},
            ]))
    statements.append("COMMIT;")
    print("\n".join(statements))


main()
