# Project Structure Documentation

## 📁 Complete Directory Structure

```
vite-gourmand/
│
├── 📄 Makefile                    # Main automation file (Windows-compatible)
├── 📄 docker-compose.yml          # Docker services configuration
├── 📄 README.md                   # Complete documentation
├── 📄 QUICKSTART.md               # Beginner-friendly quick start
├── 📄 PROJECT_STRUCTURE.md        # This file
├── 📄 .gitignore                  # Git ignore rules
│
├── 📂 server/                     # NestJS Backend Application
│   ├── 📂 src/                   # Source code
│   │   ├── 📂 prisma/           # Prisma integration
│   │   │   ├── prisma.module.ts   # Prisma module
│   │   │   └── prisma.service.ts  # Prisma service (DB connection)
│   │   ├── app.module.ts          # Main application module
│   │   ├── app.controller.ts      # Main controller (routes)
│   │   ├── app.service.ts         # Main service (business logic)
│   │   └── main.ts                # Application entry point
│   │
│   ├── 📂 prisma/                # Prisma ORM
│   │   ├── schema.prisma          # Database schema definition
│   │   └── 📂 migrations/        # Database migrations
│   │       └── .gitkeep
│   │
│   ├── 📂 dist/                  # Compiled JavaScript (generated)
│   ├── 📂 node_modules/          # Dependencies (generated)
│   │
│   ├── 📄 package.json            # Node.js dependencies
│   ├── 📄 tsconfig.json           # TypeScript configuration
│   ├── 📄 nest-cli.json           # NestJS CLI configuration
│   ├── 📄 .env                    # Environment variables
│   ├── 📄 .env.example            # Environment variables template
│   └── 📄 .gitignore              # Server-specific git ignores
│
├── 📂 client/                     # Frontend (if exists)
│   └── (Your frontend code)
│
├── 📂 scripts/                    # PowerShell automation scripts
│   ├── install.ps1                # Install dependencies
│   ├── build.ps1                  # Build application
│   ├── prisma-generate.ps1        # Generate Prisma Client
│   ├── prisma-migrate.ps1         # Run database migrations
│   ├── wait-for-db.ps1            # Wait for databases to be ready
│   ├── start-app.ps1              # Start the application
│   ├── stop-app.ps1               # Stop the application
│   ├── docker-build.ps1           # Build Docker images
│   ├── clean.ps1                  # Clean build artifacts
│   ├── fclean.ps1                 # Complete cleanup
│   └── test-setup.ps1             # Test if setup is working
│
├── 📂 data/                       # Database initialization
│   ├── 📂 postgres-init/         # PostgreSQL init scripts
│   └── 📂 mongo-init/            # MongoDB init scripts
│
└── 📂 docs/                       # Additional documentation
    └── (Your documentation)
```

## 🔍 Key Files Explained

### Root Level

#### `Makefile`
- **Purpose**: Central automation hub
- **What it does**: Orchestrates all build, run, and cleanup tasks
- **Why PowerShell**: Windows compatibility - complex multi-line commands need PowerShell scripts

#### `docker-compose.yml`
- **Purpose**: Define all Docker services
- **Services included**:
  - PostgreSQL (main database)
  - MongoDB (alternative database)
  - Alpine Linux (utility container)

### Server Directory

#### `src/main.ts`
- **Purpose**: Application entry point
- **What it does**: 
  - Starts the NestJS application
  - Configures CORS
  - Sets global API prefix (/api)
  - Listens on port 3000

#### `src/app.module.ts`
- **Purpose**: Root module
- **What it does**:
  - Imports ConfigModule for environment variables
  - Imports PrismaModule for database access
  - Registers controllers and services

#### `src/app.controller.ts`
- **Purpose**: Main HTTP route handler
- **Routes**:
  - `GET /` - Welcome message
  - `GET /health` - Health check

#### `src/prisma/prisma.service.ts`
- **Purpose**: Database connection manager
- **What it does**:
  - Extends Prisma Client
  - Connects to database on module init
  - Disconnects on module destroy

#### `prisma/schema.prisma`
- **Purpose**: Single source of truth for database schema
- **Defines**:
  - Database models (User, Recipe, Category, Review, Favorite)
  - Relationships between models
  - Indexes and constraints
  - Enums (Role, Difficulty)

### Scripts Directory

Each script is focused on a single task:

| Script | Purpose | When to Use |
|--------|---------|-------------|
| `install.ps1` | Install all dependencies | First time setup, after clean |
| `build.ps1` | Build the application | After code changes, first time |
| `prisma-generate.ps1` | Generate Prisma Client | After schema changes |
| `prisma-migrate.ps1` | Update database schema | After schema changes |
| `wait-for-db.ps1` | Wait for DB to be ready | Automatic (called by other scripts) |
| `start-app.ps1` | Start NestJS in dev mode | Daily development |
| `stop-app.ps1` | Stop the application | End of work session |
| `docker-build.ps1` | Build Docker images | When Dockerfile changes |
| `clean.ps1` | Remove build artifacts | Clean builds |
| `fclean.ps1` | Nuclear cleanup | Start completely fresh |
| `test-setup.ps1` | Verify everything works | Troubleshooting |

## 🔄 Data Flow

```
User Request
    ↓
http://localhost:3000/api/...
    ↓
main.ts (Entry Point)
    ↓
app.module.ts (Router)
    ↓
app.controller.ts (Route Handler)
    ↓
app.service.ts (Business Logic)
    ↓
prisma.service.ts (Database Access)
    ↓
Prisma Client (ORM)
    ↓
PostgreSQL Database (via Docker)
```

## 🎯 File Generation

### Generated by Build

These files are created when you run `make build`:

```
server/
├── dist/                  # Compiled JavaScript
├── node_modules/          # Installed dependencies
├── package.json           # If didn't exist
├── tsconfig.json          # If didn't exist
├── nest-cli.json          # If didn't exist
├── .env                   # If didn't exist
└── src/                   # All source files if didn't exist
```

### Generated by Prisma

These files are created when you run `make prisma-migrate`:

```
server/
├── prisma/
│   └── migrations/
│       └── 20240131_init/    # Timestamped migration
│           ├── migration.sql
│           └── migration_lock.toml
└── node_modules/
    └── .prisma/
        └── client/            # Generated Prisma Client
```

## 🗄️ Database Schema

### Tables Created

When you run `make prisma-migrate`, these tables are created in PostgreSQL:

1. **users**
   - User accounts
   - Authentication info
   - Role management

2. **recipes**
   - Recipe information
   - Ingredients and instructions
   - Metadata (prep time, difficulty, etc.)

3. **categories**
   - Recipe categorization
   - Slug for URL-friendly names

4. **recipe_categories**
   - Join table for many-to-many relationship
   - Links recipes to categories

5. **reviews**
   - User reviews of recipes
   - Ratings (1-5 stars)
   - Comments

6. **favorites**
   - User favorites
   - Links users to recipes they like

### Relationships

```
User ←→ Recipe (one-to-many: user creates many recipes)
User ←→ Review (one-to-many: user writes many reviews)
User ←→ Favorite (one-to-many: user has many favorites)
Recipe ←→ Category (many-to-many via recipe_categories)
Recipe ←→ Review (one-to-many: recipe has many reviews)
Recipe ←→ Favorite (one-to-many: recipe has many favorites)
```

## 🐳 Docker Services

### PostgreSQL Container
- **Name**: gourmand-postgres
- **Image**: postgres:16-alpine
- **Port**: 5432
- **Volume**: Persistent data storage
- **Health Check**: Automatic readiness check

### MongoDB Container
- **Name**: gourmand-mongodb
- **Image**: mongo:7-jammy
- **Port**: 27017
- **Volume**: Persistent data storage
- **Health Check**: Automatic readiness check

### Alpine Container
- **Name**: gourmand-alpine-utils
- **Image**: alpine:latest
- **Purpose**: Debugging and utilities
- **Access**: `docker exec -it gourmand-alpine-utils sh`

## 📝 Configuration Files

### Environment Variables (.env)

```env
DATABASE_URL      # PostgreSQL connection string
MONGODB_URL       # MongoDB connection string
PORT              # Application port (default: 3000)
NODE_ENV          # Environment (development/production)
```

### TypeScript Config (tsconfig.json)

Key settings:
- Target: ES2021
- Module: CommonJS
- Decorators: Enabled (required for NestJS)
- Source Maps: Enabled
- Strict Checks: Partially disabled for easier development

## 🚀 Workflow Paths

### First Time Setup
```
make install → make build → make up → make prisma-migrate
```

### Daily Development
```
make up          # Start services
(do your work)
make down        # Stop services
```

### After Schema Changes
```
(edit prisma/schema.prisma)
make prisma-migrate
make build
make up
```

### Troubleshooting
```
make status           # Check what's running
make logs            # View container logs
scripts/test-setup.ps1   # Comprehensive test
```

### Nuclear Reset
```
make fclean          # Delete everything
make install         # Reinstall
make build           # Rebuild
make up             # Start
make prisma-migrate # Setup DB
```

## 🎓 Learning Path

### Beginner Level
1. Understand what Makefile does
2. Learn basic Prisma schema syntax
3. Explore NestJS controller structure
4. Practice CRUD operations

### Intermediate Level
1. Add new models to schema
2. Create new controllers and services
3. Implement authentication
4. Add API endpoints

### Advanced Level
1. Optimize database queries
2. Add caching layer
3. Implement real-time features
4. Deploy to production

## 🔧 Customization Points

### Easy to Modify
- Database models (prisma/schema.prisma)
- API routes (*.controller.ts)
- Business logic (*.service.ts)
- Environment variables (.env)

### Moderate Difficulty
- Docker configuration (docker-compose.yml)
- Build scripts (scripts/*.ps1)
- TypeScript config (tsconfig.json)

### Advanced
- Makefile structure
- Prisma migrations
- Docker networking
- Multi-stage deployments

---

This structure is designed to be:
- ✅ Easy for beginners
- ✅ Scalable for growth
- ✅ Maintainable over time
- ✅ Windows-compatible
- ✅ Production-ready