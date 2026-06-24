# Contributing to Music Room

Thank you for your interest in contributing to Music Room! This guide will help you get started.

## 📋 Table of Contents

- [Getting Started](#getting-started)
- [Development Setup](#development-setup)
- [Project Structure](#project-structure)
- [Coding Standards](#coding-standards)
- [Git Workflow](#git-workflow)
- [Testing](#testing)
- [Pull Request Process](#pull-request-process)

## Getting Started

1. Fork the repository
2. Clone your fork: `git clone <your-fork-url>`
3. Install dependencies: `make install`
4. Create a feature branch: `git checkout -b feat/my-feature`

## Development Setup

### Prerequisites

- **Node.js** >= 20.x
- **Yarn** >= 1.22.x
- **MongoDB** >= 7.0 (or use Docker)
- **Expo CLI** for mobile development
- **Docker** (optional, for containerized development)

### Quick Start with Docker

```bash
docker-compose up -d
```

### Manual Setup

```bash
# Install dependencies
make install

# Start backend (port 3000)
make start-back

# Start frontend (port 8081)
make start-front
```

### Environment Variables

Copy the example env files and configure:

```bash
cp back/.env.example back/.env
cp front/.env.example front/.env
```

## Project Structure

```
music-room/
├── back/               # NestJS backend
│   └── src/
│       ├── modules/    # Feature modules
│       ├── common/     # Shared decorators, guards, middleware
│       └── scripts/    # Database seeds
├── front/              # Expo React Native frontend
│   ├── app/            # File-based routing (expo-router)
│   └── src/
│       ├── components/ # Reusable UI components
│       ├── hooks/      # Custom React hooks
│       ├── stores/     # Zustand state management
│       ├── services/   # API client & endpoints
│       ├── utils/      # Helper functions
│       ├── types/      # TypeScript type definitions
│       └── constants/  # App constants
├── apiREST/            # API documentation
└── load-tests/         # k6 load testing scripts
```

## Coding Standards

### TypeScript

- Use strict mode
- Prefer `interface` over `type` for object shapes
- Use descriptive variable names
- Document public APIs with JSDoc

### Backend (NestJS)

- Follow modular architecture
- Use DTOs with `class-validator` decorators
- Add Swagger decorators to all endpoints
- Write unit tests for services and controllers

### Frontend (React Native)

- Use functional components with hooks
- Store state with Zustand (not local state for shared data)
- Use `react-native-paper` components
- Follow file-based routing conventions

### Formatting

- Prettier is configured project-wide
- ESLint is configured for both backend and frontend
- Run `make lint` before committing

## Git Workflow

### Branch Naming

- `feat/description` — New features
- `fix/description` — Bug fixes
- `refactor/description` — Code refactoring
- `test/description` — Adding tests
- `docs/description` — Documentation updates

### Commit Messages

Follow [Conventional Commits](https://www.conventionalcommits.org/):

```
<type>(<scope>): <description>

[optional body]
```

Types: `feat`, `fix`, `refactor`, `test`, `docs`, `style`, `chore`, `ci`, `perf`

Scopes: `auth`, `user`, `music`, `event`, `playlist`, `delegation`, `logging`, `sub`, `iot`, `ui`, `hooks`, `store`, `utils`

### Examples

```
feat(auth): add refresh token rotation
fix(event): handle race condition in vote counting
test(playlist): add OT conflict resolution tests
docs: update API reference
```

## Testing

### Backend Tests

```bash
cd back
npm run test          # Unit tests
npm run test:cov      # Coverage report
npm run test:e2e      # E2E tests
```

### Load Tests

```bash
cd load-tests
k6 run k6-load-test.js
```

## Pull Request Process

1. Ensure all tests pass: `make test`
2. Ensure linting passes: `make lint`
3. Update documentation if needed
4. Create a PR with a clear description
5. Request review from at least one maintainer
6. Address feedback and get approval
7. Squash and merge

## Questions?

Open an issue or reach out to the maintainers. We're happy to help!
