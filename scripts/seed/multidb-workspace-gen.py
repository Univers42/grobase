# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    multidb-workspace-gen.py                           :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/10/29 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/10/29 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# The one dataset multidb-workspace.sh lands on every engine, rendered per
# dialect: two static reference tables and one churn table (rows tests edit),
# fixed ids, no randomness. Pure: reads argv/env, writes stdout, no I/O else.
# Every insert is insert-if-absent, so a re-run never reverts a test's edit.
# Row owner = MDW_ROW_OWNER (the app key's api-key:<uuid> principal; mongo also
# takes MDW_ROW_TENANT, the key's tenant), stamped
# only where the seeder writes the engine directly; gateway-loaded rows are
# stamped by the data plane itself.
#
# Usage: multidb-workspace-gen.py counts | sql-pg | sql-mysql | sql-mssql |
#        mongo-js | mongo-drop DB | sqlite-ddl | rows-int | rows-str PREFIX |
#        ids-str PREFIX | tables-str PREFIX
import json
import os
import sys

COLORS = [(1, "red", "#d32f2f"), (2, "orange", "#f57c00"), (3, "yellow", "#fbc02d"),
          (4, "green", "#388e3c"), (5, "blue", "#1976d2"), (6, "purple", "#7b1fa2")]
UNITS = [(1, "pcs", "Pieces"), (2, "kg", "Kilograms"), (3, "h", "Hours"), (4, "eur", "Euros")]
STATUSES = ["todo", "doing", "done"]
CHURN = [(i, f"Churn item {i:02d}", (i - 1) % 6 + 1, (i - 1) % 4 + 1, i * 3, STATUSES[(i - 1) % 3])
         for i in range(1, 25)]

# table -> (columns, rows); columns are (name, type) with type int|text.
TABLES = {
    "mdw_ref_color": ([("id", "int"), ("name", "text"), ("hex", "text")], COLORS),
    "mdw_ref_unit": ([("id", "int"), ("code", "text"), ("label", "text")], UNITS),
    "mdw_churn": ([("id", "int"), ("title", "text"), ("color_id", "int"), ("unit_id", "int"),
                   ("qty", "int"), ("status", "text")], CHURN),
}
STR_ID = {"mdw_ref_color": "color", "mdw_ref_unit": "unit", "mdw_churn": "churn"}
REFS = {"color_id": "color", "unit_id": "unit"}


def lit(v):
    return str(v) if isinstance(v, int) else "'" + str(v).replace("'", "''") + "'"


def owner():
    return os.environ["MDW_ROW_OWNER"]


def sql(dialect):
    types = {"pg": ("integer", "text"), "mysql": ("INT", "VARCHAR(255)"),
             "mssql": ("INT", "NVARCHAR(255)")}[dialect]
    out = []
    for table, (cols, rows) in TABLES.items():
        defs = ", ".join(f"{n} {types[0] if t == 'int' else types[1]}" + (" PRIMARY KEY" if n == "id" else "")
                         for n, t in cols) + f", owner_id {types[1]} NOT NULL"
        if dialect == "mssql":
            # GO ends the batch: sqlcmd compiles a whole batch first, so the
            # INSERTs below would fail on a table created in the same batch.
            out.append(f"IF OBJECT_ID('dbo.{table}', 'U') IS NULL CREATE TABLE dbo.{table} ({defs});\nGO")
        else:
            out.append(f"CREATE TABLE IF NOT EXISTS {table} ({defs});")
        names = ", ".join(n for n, _ in cols) + ", owner_id"
        for row in rows:
            vals = ", ".join(lit(v) for v in row) + ", " + lit(owner())
            if dialect == "pg":
                out.append(f"INSERT INTO {table} ({names}) VALUES ({vals}) ON CONFLICT (id) DO NOTHING;")
            elif dialect == "mysql":
                out.append(f"INSERT IGNORE INTO {table} ({names}) VALUES ({vals});")
            else:
                out.append(f"IF NOT EXISTS (SELECT 1 FROM dbo.{table} WHERE id = {row[0]}) "
                           f"INSERT INTO dbo.{table} ({names}) VALUES ({vals});")
        if dialect == "mssql":
            out.append("GO")
    return "\n".join(out)


def str_row(table, cols, row):
    doc = {}
    for (name, _), value in zip(cols, row):
        if name == "id":
            doc["id"] = f"{STR_ID[table]}-{value:03d}"
        elif name in REFS:
            doc[name] = f"{REFS[name]}-{value:03d}"
        else:
            doc[name] = value
    return doc


def mongo_js():
    lines = ["const d = connect(process.env.MDW_MONGO_URI);"]
    for table, (cols, rows) in TABLES.items():
        for row in rows:
            doc = str_row(table, cols, row)
            key = doc.pop("id")
            # The data plane scopes every mongo read by owner_id AND tenant_id
            # (mongo/filter.rs); $set keeps both current on documents an
            # earlier run wrote without them.
            scope = {"owner_id": owner(), "tenant_id": os.environ["MDW_ROW_TENANT"]}
            update = {"$setOnInsert": doc, "$set": scope}
            lines.append(f"d.{table}.updateOne({json.dumps({'_id': key})}, "
                         f"{json.dumps(update)}, {{upsert: true}});")
    return "\n".join(lines)


def renamed(prefix, table):
    # Namespace-less engines (redis keyspace, dynamodb account) carry the
    # workspace in the resource name: mdw_<ws32>_ref_color.
    return prefix + table[len("mdw"):] if prefix else table


def rows_lines(prefix, as_str):
    out = []
    for table, (cols, rows) in TABLES.items():
        for row in rows:
            doc = str_row(table, cols, row) if as_str else {n: v for (n, _), v in zip(cols, row)}
            out.append(f"{renamed(prefix, table)}\t{json.dumps(doc, separators=(',', ':'))}")
    return "\n".join(out)


def sqlite_ddl():
    out = []
    for table, (cols, _) in TABLES.items():
        spec = [{"name": n, "normalized_type": "integer" if t == "int" else "text", "nullable": n != "id"}
                for n, t in cols]
        body = {"op": "create_table", "table": table, "columns": spec, "primary_key": ["id"]}
        out.append(f"{table}\t{json.dumps(body, separators=(',', ':'))}")
    return "\n".join(out)


def main(argv):
    kind = argv[1] if len(argv) > 1 else ""
    arg = argv[2] if len(argv) > 2 else ""
    if kind == "counts":
        return "\n".join(f"{t} {len(rows)}" for t, (_, rows) in TABLES.items())
    if kind.startswith("sql-"):
        return sql(kind[4:])
    if kind == "mongo-js":
        return mongo_js()
    if kind == "mongo-drop":
        return f"connect(process.env.MDW_MONGO_URI).getSiblingDB({json.dumps(arg)}).dropDatabase();"
    if kind == "sqlite-ddl":
        return sqlite_ddl()
    if kind == "rows-int":
        return rows_lines("", False)
    if kind == "rows-str":
        return rows_lines(arg, True)
    if kind == "ids-str":
        return "\n".join(f"{renamed(arg, t)}\t{STR_ID[t]}-{r[0]:03d}" for t, (_, rows) in TABLES.items() for r in rows)
    if kind == "tables-str":
        return ",".join(renamed(arg, t) for t in TABLES)
    sys.exit(f"multidb-workspace-gen.py: unknown kind '{kind}'")


if __name__ == "__main__":
    print(main(sys.argv))
