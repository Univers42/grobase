# MongoDB

MongoDB 7 — document-oriented NoSQL database. Stores JSON-like documents with flexible schemas, used for multi-database support alongside PostgreSQL.

## Quick Start

```bash
docker compose up mongo
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `MONGO_INITDB_ROOT_USERNAME` | — | Root admin username |
| `MONGO_INITDB_ROOT_PASSWORD` | — | Root admin password |
| `MONGO_INITDB_DATABASE` | — | Database created on first run |

## Ports

| Port | Description |
|------|-------------|
| `27017` | MongoDB wire protocol |

## Volumes

| Volume | Mount Point | Description |
|--------|------------|-------------|
| `mongo-data` | `/data/db` | Persistent database storage |

## CLI Examples

```bash
# Connect with mongosh (inside container)
docker compose exec mongo mongosh -u root -p <password>

# Connect from host (if port is exposed)
mongosh "mongodb://root:<password>@localhost:27017"

# Show databases
docker compose exec mongo mongosh -u root -p <password> --eval "show dbs"

# Create a collection and insert a document
docker compose exec mongo mongosh -u root -p <password> --eval '
  use mydb;
  db.users.insertOne({ name: "Alice", email: "alice@example.com" });
'

# Find documents
docker compose exec mongo mongosh -u root -p <password> --eval '
  use mydb;
  db.users.find().pretty();
'

# Find with filter
docker compose exec mongo mongosh -u root -p <password> --eval '
  use mydb;
  db.users.find({ name: "Alice" }).pretty();
'

# Update a document
docker compose exec mongo mongosh -u root -p <password> --eval '
  use mydb;
  db.users.updateOne({ name: "Alice" }, { $set: { email: "alice@new.com" } });
'

# Delete a document
docker compose exec mongo mongosh -u root -p <password> --eval '
  use mydb;
  db.users.deleteOne({ name: "Alice" });
'

# Create an index
docker compose exec mongo mongosh -u root -p <password> --eval '
  use mydb;
  db.users.createIndex({ email: 1 }, { unique: true });
'

# Backup with mongodump
docker compose exec mongo mongodump -u root -p <password> --out /tmp/backup

# Restore with mongorestore
docker compose exec mongo mongorestore -u root -p <password> /tmp/backup
```

## Health Check

```bash
docker compose exec mongo mongosh -u root -p <password> --eval "db.adminCommand('ping')"
```

Returns `{ ok: 1 }` when the server is healthy.

## Docker

- **Image:** `mongo:7`
- **Port:** `27017`
- **Volumes:** `mongo-data:/data/db`
- **Init scripts:** JavaScript/shell files in `/docker-entrypoint-initdb.d/` run on first start
- **Networks:** Internal `baas` network
