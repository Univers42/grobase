# Savanna Park Zoo — BaaS Showcase App

A full-featured zoo management website running entirely on the **real mini-BaaS infrastructure**. No mocks, no simulations — every API call hits real services.

## Architecture

```
┌─────────────────────────────────────────────────┐
│  Browser  →  http://localhost:5173 (dev)        │
│              http://localhost:5180 (Docker)      │
└────────────────────┬────────────────────────────┘
                     │  fetch()
┌────────────────────▼────────────────────────────┐
│  Kong API Gateway  →  http://localhost:8000     │
│  ├─ /auth/v1/*     → GoTrue   (auth)           │
│  ├─ /rest/v1/*     → PostgREST (CRUD)          │
│  ├─ /realtime/v1/* → Realtime  (SSE)           │
│  └─ /storage/v1/*  → MinIO    (files)          │
└────────────────────┬────────────────────────────┘
                     │
┌────────────────────▼────────────────────────────┐
│  PostgreSQL 16                                   │
│  ├─ animals, events, feeding_logs                │
│  ├─ health_records, visitor_messages             │
│  ├─ staff, ticket_types, tickets                 │
│  └─ visitor_stats (auto-aggregate)               │
└──────────────────────────────────────────────────┘
```

### Source Layout

```
infra/                    ← Database init + Docker config
├── 001_zoo_tables.sql    ← Table definitions (10 tables)
├── 002_zoo_functions.sql ← Triggers (updated_at, QR, stats)
├── 003_zoo_seed.sql      ← Seed data
├── init.sh               ← Bootstrap script
└── nginx.conf            ← Frontend server config

front/                    ← React 18 + Vite frontend
├── src/
│   ├── baas/client.js    ← BaaS SDK (PostgREST + GoTrue via Kong)
│   ├── hooks/            ← useBaasCollection, useBaasAuth, useBaasRealtime
│   ├── stores/           ← Zustand stores (auth, animals)
│   └── pages/
│       ├── Home, Animals, AnimalDetail, Events, Tickets, Contact
│       └── admin/ → Login, Dashboard, Animals, Health, Feeding,
│                    Tickets, Events, Staff, Messages

model/                    ← Model layer documentation (schemas, seeds, rules)
```

## Quick Start

```bash
# From this directory (sandbox/apps/app2)
make all
```

This single command:

1. Builds the React frontend (`pnpm build`)
2. Starts the BaaS infrastructure (PostgreSQL, Kong, GoTrue, PostgREST, …)
3. Seeds the zoo database (10 tables, auth users)
4. Serves the app via nginx at http://localhost:5180

## Development

```bash
# Start BaaS + seed data
make baas-up seed

# Hot-reload dev server (port 5173)
make dev
```

## Staff Login

| Name            | Email                          | Role      | Password       |
| --------------- | ------------------------------ | --------- | -------------- |
| Sophie Laurent  | sophie.laurent@savanna-zoo.com | admin     | zoo-admin-2024 |
| Marcus Osei     | marcus.osei@savanna-zoo.com    | zookeeper | zoo-admin-2024 |
| Elena Moreau    | elena.moreau@savanna-zoo.com   | zookeeper | zoo-admin-2024 |
| Dr. Yuki Tanaka | yuki.tanaka@savanna-zoo.com    | vet       | zoo-admin-2024 |
| Lucas Petit     | lucas.petit@savanna-zoo.com    | reception | zoo-admin-2024 |

## Makefile Targets

| Target         | Description                                |
| -------------- | ------------------------------------------ |
| `make all`     | Full pipeline: build → BaaS → seed → serve |
| `make dev`     | Vite dev server with HMR (port 5173)       |
| `make build`   | Build frontend to `front/dist/`            |
| `make baas-up` | Start BaaS infrastructure                  |
| `make seed`    | Seed zoo data (re-runnable)                |
| `make reset`   | Drop + reseed zoo data                     |
| `make serve`   | Serve built frontend via Docker            |
| `make down`    | Stop zoo frontend container                |
| `make status`  | Show container status                      |
| `make clean`   | Remove dist/ and containers                |

## Design

**"Organic Luxury Safari"** — Deep forest green + warm sand + burnt amber + ivory.
Fonts: Cormorant Garamond (display) · DM Sans (body).

## BaaS Features Demonstrated

- **Real REST API**: PostgREST serves every table via Kong gateway
- **Real Auth**: GoTrue handles sign-up/sign-in with JWT tokens
- **Real-time**: SSE subscriptions for live ticket/feeding/message updates
- **Triggers**: Auto QR codes on tickets, auto visitor_stats aggregation
- **Resource embedding**: PostgREST joins (e.g. animal → keeper)
- **Full CRUD**: All 9 admin pages create, read, update, delete records
