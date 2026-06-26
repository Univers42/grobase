#!/usr/bin/env python3
# **************************************************************************** #
#  extra-engines-gen.py — deterministic data for osionos-extra-engines.sh      #
#                                                                              #
#  One generator, four output modes (chosen by argv[1]); every row is          #
#  owner-stamped and reproducible (a seed-42 LCG, no `random` import so a       #
#  re-run is byte-identical across machines):                                  #
#    restaurant         → TSV `table<TAB>json` lines  (sqlite, gateway insert)  #
#    finance            → a T-SQL script              (mssql, sqlcmd)           #
#    iot <outdir>       → batch-write-item JSON files (dynamodb, aws-cli)       #
#    edges              → an INSERT block for commerce.public.edges             #
#                                                                              #
#  Owner principals come from env (SQLITE_OWNER / MSSQL_OWNER / DDB_OWNER /     #
#  EDGE_OWNER); registered dbIds for the edges' graph node ids come from        #
#  EDGE_SQLITE / EDGE_MSSQL / EDGE_DYNAMO / EDGE_COMMERCE.                      #
# **************************************************************************** #
import json
import os
import sys

# Existing commerce reference ranges (real seeded rows the edges point at).
CUSTOMERS = 500      # customers 1..500 (a safe subset of the live 1..5000)
PRODUCTS = 1200      # products 1..1200
ORDERS = 25000       # orders   1..25000

CUISINES = ["Italian", "Japanese", "Mexican", "Indian", "French",
            "Thai", "Greek", "Lebanese", "Korean", "Spanish"]
CITIES = ["Paris", "Lyon", "Marseille", "Bordeaux", "Lille",
          "Nantes", "Nice", "Toulouse", "Rennes", "Strasbourg"]
DISHES = ["Margherita", "Ramen", "Tacos", "Curry", "Coq au Vin",
          "Pad Thai", "Moussaka", "Hummus", "Bibimbap", "Paella",
          "Risotto", "Gyoza", "Burrito", "Naan", "Crêpe"]
ORDER_STATUS = ["placed", "preparing", "delivered", "cancelled"]
DEVICE_KINDS = ["thermostat", "camera", "door-lock", "motion", "smoke", "valve"]
ALERT_LEVELS = ["info", "warning", "critical"]


class Lcg:
    """A tiny seeded LCG (glibc constants) so output is deterministic without
    importing `random` (whose stream is version-stable but heavier)."""

    def __init__(self, seed=42):
        self.state = seed & 0x7FFFFFFF

    def next(self):
        self.state = (1103515245 * self.state + 12345) & 0x7FFFFFFF
        return self.state

    def below(self, n):
        return self.next() % n

    def pick(self, seq):
        return seq[self.below(len(seq))]

    def between(self, lo, hi):
        return lo + self.below(hi - lo + 1)


def emit_restaurant():
    """sqlite: 8 restaurants, menus, dishes, ~600 orders, ~1500 items, hours."""
    rng = Lcg(42)
    owner = os.environ["SQLITE_OWNER"]
    out = sys.stdout

    def line(table, obj):
        obj["owner_id"] = owner
        out.write(f"{table}\t{json.dumps(obj, separators=(',', ':'))}\n")

    n_rest = 8
    for r in range(1, n_rest + 1):
        line("restaurant", {"id": r, "name": f"{rng.pick(CUISINES)} House {r}",
                            "cuisine": rng.pick(CUISINES), "city": rng.pick(CITIES)})
    menu_id = 0
    dish_id = 0
    rest_menu = {}
    rest_dishes = {}
    for r in range(1, n_rest + 1):
        menu_id += 1
        line("menu", {"id": menu_id, "restaurant_id": r, "name": f"Menu {r}"})
        rest_menu[r] = menu_id
        rest_dishes[r] = []
        for _ in range(rng.between(6, 12)):
            dish_id += 1
            line("dish", {"id": dish_id, "menu_id": menu_id,
                         "name": rng.pick(DISHES),
                         "price_cents": rng.between(800, 3600)})
            rest_dishes[r].append(dish_id)
    for r in range(1, n_rest + 1):
        for wd in range(7):
            line("working_hours", {"id": r * 10 + wd, "restaurant_id": r,
                                  "weekday": wd, "opens": "11:00", "closes": "23:00"})
    # 300 orders → these are the rows the restaurant_order→customer edges link.
    # Kept modest: each row is a single-row gateway insert under a 300/min cap,
    # so the whole sqlite load stays a few minutes, not an hour.
    item_id = 0
    for o in range(1, 301):
        r = rng.between(1, n_rest)
        total = 0
        n_items = rng.between(1, 3)
        items = []
        for _ in range(n_items):
            item_id += 1
            d = rng.pick(rest_dishes[r])
            q = rng.between(1, 3)
            items.append((item_id, d, q))
            total += q * rng.between(800, 3600)
        line("restaurant_order", {"id": o, "restaurant_id": r,
                                 "customer_ref": rng.between(1, CUSTOMERS),
                                 "status": rng.pick(ORDER_STATUS),
                                 "total_cents": total})
        for (iid, d, q) in items:
            line("order_item", {"id": iid, "order_id": o, "dish_id": d, "qty": q})


def _tsql_str(s):
    return "N'" + s.replace("'", "''") + "'"


def emit_finance():
    """mssql: a T-SQL script — DROP+CREATE the 5 tables, then bulk INSERTs.
    Idempotent: DROP IF EXISTS makes a re-run converge on identical rows."""
    rng = Lcg(42)
    owner = os.environ["MSSQL_OWNER"]
    o = sys.stdout.write
    o("SET NOCOUNT ON;\n")
    tables = {
        "invoice_lines": "DROP TABLE IF EXISTS dbo.invoice_lines;",
        "payments": "DROP TABLE IF EXISTS dbo.payments;",
        "invoices": "DROP TABLE IF EXISTS dbo.invoices;",
        "gl_accounts": "DROP TABLE IF EXISTS dbo.gl_accounts;",
        "cost_centers": "DROP TABLE IF EXISTS dbo.cost_centers;",
    }
    for stmt in tables.values():
        o(stmt + "\n")
    o("""CREATE TABLE dbo.gl_accounts (id INT PRIMARY KEY, code NVARCHAR(16), name NVARCHAR(64), owner_id NVARCHAR(128));
CREATE TABLE dbo.cost_centers (id INT PRIMARY KEY, name NVARCHAR(64), region NVARCHAR(32), owner_id NVARCHAR(128));
CREATE TABLE dbo.invoices (id INT PRIMARY KEY, order_ref INT, customer_ref INT, status NVARCHAR(16), amount_cents INT, gl_account_id INT, owner_id NVARCHAR(128));
CREATE TABLE dbo.invoice_lines (id INT PRIMARY KEY, invoice_id INT, description NVARCHAR(64), qty INT, unit_cents INT, owner_id NVARCHAR(128));
CREATE TABLE dbo.payments (id INT PRIMARY KEY, invoice_id INT, customer_ref INT, method NVARCHAR(16), amount_cents INT, owner_id NVARCHAR(128));
""")
    ow = _tsql_str(owner)

    def bulk(table, cols, rows):
        # sqlcmd reads input line-by-line and splits very long lines mid-token
        # (seen: "Incorrect syntax near …" on 40 KB lines). Keep each INSERT
        # well under that: 20 rows/statement → short lines, still few batches.
        for i in range(0, len(rows), 20):
            chunk = rows[i:i + 20]
            vals = ",".join("(" + ",".join(r) + ")" for r in chunk)
            o(f"INSERT INTO dbo.{table} ({cols}) VALUES {vals};\n")

    glr = [[str(a), _tsql_str(f"{4000 + a}"), _tsql_str(rng.pick(['Revenue', 'COGS', 'Opex', 'Tax', 'Payroll']) + f" {a}"), ow]
           for a in range(1, 21)]
    bulk("gl_accounts", "id,code,name,owner_id", glr)
    ccr = [[str(c), _tsql_str(f"Cost Center {c}"), _tsql_str(rng.pick(['EU', 'NA', 'APAC', 'LATAM'])), ow]
           for c in range(1, 13)]
    bulk("cost_centers", "id,name,region,owner_id", ccr)

    # invoices 1..600 → invoice→order + payment→customer edges link to these.
    inv = []
    for i in range(1, 601):
        amt = rng.between(5000, 200000)
        inv.append([str(i), str(rng.between(1, ORDERS)), str(rng.between(1, CUSTOMERS)),
                    _tsql_str(rng.pick(['draft', 'sent', 'paid', 'overdue'])),
                    str(amt), str(rng.between(1, 20)), ow])
    bulk("invoices", "id,order_ref,customer_ref,status,amount_cents,gl_account_id,owner_id", inv)

    lines = []
    lid = 0
    for i in range(1, 601):
        for _ in range(rng.between(1, 4)):
            lid += 1
            lines.append([str(lid), str(i),
                          _tsql_str(rng.pick(['Setup', 'Hosting', 'Support', 'License', 'Consulting'])),
                          str(rng.between(1, 10)), str(rng.between(1000, 25000)), ow])
    bulk("invoice_lines", "id,invoice_id,description,qty,unit_cents,owner_id", lines)

    pays = []
    for p in range(1, 401):
        pays.append([str(p), str(rng.between(1, 600)), str(rng.between(1, CUSTOMERS)),
                     _tsql_str(rng.pick(['card', 'wire', 'cash', 'paypal'])),
                     str(rng.between(5000, 200000)), ow])
    bulk("payments", "id,invoice_id,customer_ref,method,amount_cents,owner_id", pays)


def _ddb_item(owner, id_, attrs):
    item = {"owner_pk": {"S": owner}, "id": {"S": id_}, "owner": {"S": owner}}
    for k, v in attrs.items():
        item[k] = {"N": str(v)} if isinstance(v, (int, float)) else {"S": str(v)}
    return {"PutRequest": {"Item": item}}


def emit_iot(outdir):
    """dynamodb: write batch-write-item request files (≤25 PutRequests each).
    owner_pk = the owner principal so the adapter's owner-partition Query
    returns them. devices 1..200 → device→product edges link to these."""
    rng = Lcg(42)
    owner = os.environ["DDB_OWNER"]
    by_table = {"devices": [], "device_events": [], "alerts": []}

    for d in range(1, 201):
        by_table["devices"].append(_ddb_item(owner, f"dev-{d:04d}", {
            "kind": rng.pick(DEVICE_KINDS),
            "product_ref": rng.between(1, PRODUCTS),
            "firmware": f"{rng.between(1, 4)}.{rng.between(0, 9)}.{rng.between(0, 9)}",
            "site": rng.pick(CITIES),
        }))
    for e in range(1, 1201):
        by_table["device_events"].append(_ddb_item(owner, f"evt-{e:05d}", {
            "device_ref": f"dev-{rng.between(1, 200):04d}",
            "metric": rng.pick(["temp", "humidity", "battery", "rssi"]),
            "value": rng.between(0, 100),
            "ts": 1750000000 + e * 37,
        }))
    for a in range(1, 251):
        by_table["alerts"].append(_ddb_item(owner, f"alrt-{a:04d}", {
            "device_ref": f"dev-{rng.between(1, 200):04d}",
            "level": rng.pick(ALERT_LEVELS),
            "code": rng.between(100, 599),
        }))

    fidx = 0
    for table, items in by_table.items():
        for i in range(0, len(items), 25):
            chunk = items[i:i + 25]
            fidx += 1
            path = os.path.join(outdir, f"batch-{fidx:04d}.json")
            with open(path, "w") as f:
                json.dump({table: chunk}, f, separators=(",", ":"))


def _edge_row(src_kind, src_id, dst_kind, dst_id, rel, frm, to, owner):
    def q(s):
        return "'" + str(s).replace("'", "''") + "'"
    return "(" + ",".join([q(src_kind), q(src_id), q(dst_kind), q(dst_id),
                           q(rel), q(frm), q(to), q(rel), q(owner)]) + ")"


def emit_edges():
    """commerce.edges: ~100-300 edges per kind, INTERLEAVED by kind so the
    bounded overview (EDGE_FANOUT 1000) shows a mix. A missing dbId drops its
    kind cleanly (no orphan node ids)."""
    rng = Lcg(42)
    owner = os.environ["EDGE_OWNER"]
    sqlite_db = os.environ.get("EDGE_SQLITE", "")
    mssql_db = os.environ.get("EDGE_MSSQL", "")
    dynamo_db = os.environ.get("EDGE_DYNAMO", "")
    commerce = os.environ["EDGE_COMMERCE"]

    kinds = []  # list of (generator) iterators yielding edge-row SQL tuples
    per = 250

    def invoice_order():
        for i in range(1, per + 1):
            order = rng.between(1, ORDERS)
            yield _edge_row("invoice", i, "order", order, "invoice_for_order",
                            f"{mssql_db}:invoices:{i}",
                            f"{commerce}:orders:{order}", owner)

    def payment_customer():
        for p in range(1, per + 1):
            cust = rng.between(1, CUSTOMERS)
            yield _edge_row("payment", p, "customer", cust, "payment_by_customer",
                            f"{mssql_db}:payments:{p}",
                            f"{commerce}:customers:{cust}", owner)

    def rorder_customer():
        for o in range(1, per + 1):
            cust = rng.between(1, CUSTOMERS)
            yield _edge_row("restaurant_order", o, "customer", cust, "rorder_by_customer",
                            f"{sqlite_db}:restaurant_order:{o}",
                            f"{commerce}:customers:{cust}", owner)

    def device_product():
        for d in range(1, per + 1):
            prod = rng.between(1, PRODUCTS)
            did = f"dev-{d:04d}"
            yield _edge_row("device", did, "product", prod, "device_for_product",
                            f"{dynamo_db}:devices:{did}",
                            f"{commerce}:products:{prod}", owner)

    if mssql_db:
        kinds.append(invoice_order())
        kinds.append(payment_customer())
    if sqlite_db:
        kinds.append(rorder_customer())
    if dynamo_db:
        kinds.append(device_product())

    rows = []
    exhausted = False
    while not exhausted:
        exhausted = True
        for it in kinds:
            try:
                rows.append(next(it))
                exhausted = False
            except StopIteration:
                pass

    if not rows:
        return
    o = sys.stdout.write
    o("BEGIN;\n")
    for i in range(0, len(rows), 500):
        chunk = rows[i:i + 500]
        o("INSERT INTO public.edges "
          "(src_kind,src_id,dst_kind,dst_id,rel,\"from\",\"to\",\"type\",owner_id) VALUES\n")
        o(",\n".join(chunk))
        o("\nON CONFLICT (src_kind,src_id,dst_kind,dst_id,rel) DO NOTHING;\n")
    o("COMMIT;\n")


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else ""
    if mode == "restaurant":
        emit_restaurant()
    elif mode == "finance":
        emit_finance()
    elif mode == "iot":
        emit_iot(sys.argv[2])
    elif mode == "edges":
        emit_edges()
    else:
        sys.stderr.write(f"unknown mode: {mode!r}\n")
        sys.exit(2)


if __name__ == "__main__":
    main()
