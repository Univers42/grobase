# Makefile Setup Guide

## Problem Fixed
The Makefile was trying to run Prisma migrations without:
1. Loading the `DATABASE_URL` environment variable
2. Installing backend dependencies
3. Generating the Prisma client
4. Ensuring PostgreSQL was ready

This caused the error: `Error: The datasource.url property is required in your Prisma config file`

## Solution Applied

### 1. Created `backend/.env`
```
DATABASE_URL=postgresql://postgres:postgres@localhost:5432/vite_gourmand?schema=public
```
This matches the PostgreSQL service in `docker-compose.yml`.

### 2. Improved `Makefile`
The Makefile now:
- Loads `DATABASE_URL` from `backend/.env` at the top
- Defines all variables before using them
- Installs backend npm dependencies before any Prisma commands
- Generates Prisma Client before running migrations
- Exports `DATABASE_URL` to all Prisma commands

### 3. Default Workflow
Running `make` (or `make all`) now:
```
make all
├── up                  (docker-compose up -d)
├── wait-for-db         (waits for PostgreSQL ready)
├── install-backend     (npm install in ./backend)
├── generate-prisma     (prisma generate)
├── init-migration      (prisma migrate dev --name init)
└── reset               (prisma migrate reset --force)
```

## Usage

### First-time setup
```bash
make all
```

### After pulling new migrations
```bash
make migrate
```

### Reset database (WARNING: destroys all data)
```bash
make reset
```

### Reload everything
```bash
make reload
```

### Install frontend/backend deps only
```bash
make restore
```

### Clean up
```bash
make down      # Stop containers, keep data
make clean     # Remove containers and images, keep data
make destroy   # Remove everything including data
```

### Other commands
```bash
make psql      # Open psql shell
make logs      # Show container logs
make help      # Show all available commands
```

## Database Tables Created
All tables from `backend/prisma/schema.prisma` are now automatically created and migrated:
- User, Role, Publish, Order
- Menu, Diet, Theme, Dish, Allergen
- WorkingHours
- Junction tables (_OrderMenus, _DishAllergens)
- Prisma migration tracking (_prisma_migrations)

## Troubleshooting

**If migrations fail:**
```bash
make down
make destroy        # Clean everything
make all           # Start fresh
```

**If database connection fails:**
- Check `backend/.env` exists and has correct DATABASE_URL
- Ensure PostgreSQL container is running: `docker ps`
- Wait longer for DB: `make wait-for-db`

**If npm install fails:**
```bash
cd backend
rm -rf node_modules package-lock.json
npm install
cd ..
make all
```
