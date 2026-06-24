# Vite & Gourmand

A restaurant ordering platform built as the final assessment (ECF) for the Studi full-stack web developer curriculum by Dylan Lesieur.

> Designed to be hackable, observable, and pleasant to use — from a blank slate to a production-ready app.

**Live:** https://vite-gourmand-withered-glitter-7902.fly.dev &nbsp;·&nbsp; **Region:** Paris (cdg) &nbsp;·&nbsp; **Docs:** [`/api/docs`](https://vite-gourmand-withered-glitter-7902.fly.dev/api/docs)

---

## Table of Contents

- [Quick Start](#quick-start)
- [Environment Variables](#environment-variables)
- [Project Context](#project-context)
- [Architecture](#architecture)
- [Make Commands Reference](#make-commands-reference)
- [Demo Accounts](#demo-accounts)
- [Deployment](#deployment)
- [References](#references)

---

## Quick Start

Three ways to run the project. Docker is the safest for a fresh machine.

### Option 1 — Docker (recommended, no Node.js required)

Only Docker needs to be installed on the host.

```bash
git clone <repository-url>
cd vite-gourmand

# If you use Bitwarden to manage the .env:
export BW_SESSION=$(bw unlock --raw)
make                          # fetches .env, installs deps, starts everything
```

If you already have a `Back/.env` file:

```bash
make docker-bootstrap         # skips Bitwarden, uses existing .env
```

Servers come up at:

| Service        | URL                         |
|----------------|-----------------------------|
| Frontend       | http://localhost:5173        |
| Backend API    | http://localhost:3000/api    |
| Swagger UI     | http://localhost:3000/api/docs |
| Prisma Studio  | http://localhost:5555        |

---

### Option 2 — Local Node.js (Node 20+ required)

```bash
git clone <repository-url>
cd vite-gourmand

# Copy and fill in the environment file first (see Environment Variables below)
cp Back/.env.example Back/.env   # or create Back/.env manually

make local                        # installs deps, migrates DB, starts servers
```

Stop with `make turn-off`. Restart with `make turn-on`.

---

### Option 3 — VS Code Dev Container

Full IDE support (extensions, debugger, terminal) running inside the same Docker environment.

1. Install the [Dev Containers](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-containers) extension.
2. Open the project folder.
3. When prompted, click **Reopen in Container** (or `F1` → *Dev Containers: Reopen in Container*).
4. The container builds once; subsequent opens are instant.

---

## Environment Variables

Create `Back/.env`. The required variables are:

```dotenv
# ── Database ──────────────────────────────────────────────
DATABASE_URL=postgresql://postgres:postgres@localhost:5432/vite_gourmand
MONGODB_URI=mongodb://root:example@localhost:27017/vite_gourmand?authSource=admin

# ── Auth ──────────────────────────────────────────────────
JWT_SECRET=change-me-to-a-long-random-string

# ── App ───────────────────────────────────────────────────
PORT=3000
NODE_ENV=development
FRONTEND_URL=http://localhost:5173

# ── Google OAuth (optional — leave blank to disable) ──────
GOOGLE_CLIENT_ID=
GOOGLE_CLIENT_SECRET=

# ── Email / SMTP (Titan, optional) ────────────────────────
TITAN_EMAIL=
TITAN_PASSWORD=
TITAN_SMTP_HOST=smtp.titan.email
TITAN_SMTP_PORT=465

# ── External APIs (optional — app falls back to demo data) ─
GROQ_API_KEY=
API_UNSPLASH_PKEY=
```

The Docker setup (`make docker-bootstrap`) can fetch these from a Bitwarden vault item named `vite-gourmand-env`. To use a different item name:

```bash
BW_ITEM_NAME=my-vault-item make
```

---

## Project Context

**Vite & Gourmand** is a fictional Parisian restaurant run by Julie and José. Faced with growing demand and new opportunities, they hired *FastDev* — a small dev shop — to build them a web presence.

The app lets customers browse the menu and place orders online. Staff and administrators get a back-office to manage dishes, track orders, handle staff scheduling, and monitor analytics.

This is my ECF (Évaluation en Cours de Formation) project for the *Titre Professionnel Développeur Web et Web Mobile* at Studi, started January 30 2026. The requirements brief is in [`docs/requirements.md`](docs/requirements.md).

---

## Architecture

```mermaid
flowchart TD
    subgraph Browser["Browser"]
        FE["React 19 + TypeScript<br/>Vite 6 · Tailwind CSS v4 · Radix UI<br/>TanStack Query · React Router · Recharts"]
    end

    subgraph Server["NestJS 11 — API Server"]
        direction TB
        SEC["Helmet · CSRF · compression"]
        G["Guards — JWT, RBAC<br/>user / employee / admin"]
        I["Interceptors — logging, transform"]
        C["Controllers"]
        S["Services"]
        P["PrismaService"]
        WS["WebSockets<br/>real-time orders + chat"]
        DOC["Swagger — OpenAPI 3.0"]

        SEC --> G --> I --> C --> S --> P
        S -.-> WS
    end

    PG[("PostgreSQL 15<br/>46 domain models")]
    MG[("MongoDB 7<br/>analytics, logs, activity")]

    Browser -- "HTTPS / REST + Cookie Auth" --> Server
    P -- "Prisma ORM" --> PG
    S -- "Mongoose" --> MG
```

### Stack at a glance

| Layer        | Technology                                  |
|--------------|---------------------------------------------|
| Frontend     | React 19, TypeScript, Vite 6                |
| Styling      | Tailwind CSS v4, Radix UI, CSS design tokens |
| Backend      | NestJS 11, TypeScript, Node.js 22           |
| ORM          | Prisma 7 (PostgreSQL)                       |
| NoSQL        | MongoDB 7 via Mongoose                      |
| Auth         | JWT (access + refresh), bcrypt, CSRF cookies |
| Realtime     | WebSockets (`@nestjs/websockets`)           |
| API docs     | Swagger / OpenAPI (`@nestjs/swagger`)       |
| Testing      | Jest (unit + e2e), Postman collections      |
| CI           | GitHub Actions (lint → test → security)     |
| Deployment   | Fly.io (Paris cdg, 1 vCPU / 1 GB RAM)      |

### Database models

The PostgreSQL schema covers 46 models including: `User`, `Role`, `Permission`, `Company`, `Menu`, `Dish`, `Order`, `OrderMenu`, `Allergen`, `Ingredient`, `KanbanColumn`, `LoyaltyAccount`, `Promotion`, `Discount`, `SupportTicket`, `NewsletterSubscriber`, `Event`, and more. See [`docs/data-model.md`](docs/data-model.md) and the Prisma schema at `Back/src/Model/prisma/schema.prisma`.

### Diagrams

- [NestJS module map & request flow](docs/diagrams/nestjs-modules.md) — Fig. 7
- [Database ERD](docs/database-erd.md)
- [Use-case diagram](docs/use-case-diagram.md)
- [Sequence diagram](docs/sequence-diagram.md)

---

## Make Commands Reference

Run `make help` for the full grouped list. Key commands:

```
Bootstrap
  make                    Full Docker bootstrap (default)
  make docker-bootstrap   Same as above, explicit
  make local              Bootstrap with host Node.js
  make secrets            Fetch Back/.env from Bitwarden

Servers
  make turn-on            Start backend + frontend (host Node.js)
  make turn-off           Stop all local dev servers
  make docker-shell       Open shell inside the dev container
  make docker-restart     Restart servers inside the container

Database
  make db-migrate         Run pending Prisma migrations
  make db-seed            Seed with demo data
  make db-studio          Open Prisma Studio (http://localhost:5555)
  make db-reset           Drop and re-migrate the database
  make db-connect         psql session into the running database

Tests
  make test               Run unit tests
  make test-e2e           Run end-to-end tests
  make test-all           Unit + e2e + custom flows
  make coverage           Generate coverage report

Security
  make security-all       Full security audit (deps + headers + secrets)

Deploy
  make deploy             Deploy to Fly.io (requires flyctl)
  make deploy-status      Show current deployment status

Cleanup
  make clean              Remove build artifacts
  make fclean             Remove containers, volumes, build artifacts
```

---

## Demo Accounts

After seeding the database (`make db-seed`), these accounts are available:

| Role          | Email                | Password     |
|---------------|----------------------|--------------|
| Admin         | admin@demo.app       | Admin123!@#  |
| Employee      | employee@demo.app    | Employee123! |
| Customer      | client@demo.app      | Client123!   |

The admin account has full access to the back-office: menu management, order tracking, staff management, analytics, and system logs.

---

## Deployment

The app is deployed to **Fly.io** as a single container (NestJS serves the compiled React build as static files from `/public`).

```bash
# Prerequisites: Docker. flyctl runs inside the Compose fly service.
# Put FLY_API_TOKEN or FLY_ACCESS_TOKEN in .env.production for Fly API auth.
make deploy           # builds Docker image and deploys
make deploy-status    # shows machine and service health
make deploy-logs      # tail production logs
make deploy-certs     # inspect/request Fly managed certificates
```

Production config: [`infrastructure/services/fly/config/fly.toml`](infrastructure/services/fly/config/fly.toml) — Paris region, 1 vCPU, 1 GB RAM, auto-stop when idle.

The CI pipeline runs on every push to `main`: lint → unit tests + e2e → security scan (OWASP-style header check, dependency audit). The deploy step is manual to avoid accidental production pushes.

---

## Project Structure

```
vite-gourmand/
├── Back/                   NestJS backend
│   ├── src/
│   │   ├── app.module.ts
│   │   ├── main.ts         Bootstrap, CORS, Helmet, body parser
│   │   ├── auth/           JWT auth, CSRF, Google OAuth
│   │   ├── users/
│   │   ├── menus/
│   │   ├── orders/
│   │   ├── admin/
│   │   ├── Model/
│   │   │   └── prisma/     schema.prisma (46 models)
│   │   └── ...
│   └── test/               Jest unit + e2e specs
│
├── View/                   React + Vite frontend
│   └── src/
│       ├── components/     UI components (layout, features, helpers)
│       ├── scenarios/      Route-level views (auth, kanban, orders)
│       ├── portal_dashboard/ Staff / admin portal
│       └── styles/         CSS design tokens (graphical_chart*.css)
│
├── docs/                   Architecture docs, diagrams, guides
├── infrastructure/          Docker service definitions, contracts, deployment config
├── scripts/                Setup and utility scripts
├── mk_extensions/          Makefile targets split by domain
├── docker-compose.yml      PostgreSQL + MongoDB + dev container
└── .env.production.example Production transport policy template
```

---

## References

| Topic | Link |
|-------|------|
| Requirements brief | [docs/requirements.md](docs/requirements.md) |
| API documentation | [docs/API_DOCUMENTATION.md](docs/API_DOCUMENTATION.md) |
| Security guide | [docs/security-guide.md](docs/security-guide.md) |
| RGPD compliance | [docs/rgpd.md](docs/rgpd.md) |
| RGAA accessibility | [docs/rgaa.md](docs/rgaa.md) |
| Glossary | [docs/glossary.md](docs/glossary.md) |
| GitHub project board | https://github.com/users/LESdylan/projects/3 |
| NestJS docs | https://docs.nestjs.com |
| Prisma docs | https://www.prisma.io/docs |
| Tailwind CSS v4 | https://tailwindcss.com/docs |
| Fly.io docs | https://fly.io/docs |
| RGAA | https://accessibilite.numerique.gouv.fr |
| Unsplash API | https://unsplash.com/documentation |

---

## Use of AI

Used as a study aid for clarifying architectural trade-offs, researching library APIs, and understanding edge cases in standards (RGAA, RGPD, JWT security). Logic design and implementation decisions are my own.

## License

[MIT](LICENSE) — Dylan Lesieur, 2026
