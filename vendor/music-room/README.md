# Music Room

> Music, Collaboration and Mobility

A complete mobile solution focused on music and user experience, built with a **modular monolithic architecture**.

## Architecture

- **Back-end**: NestJS modular monolith (TypeScript, MongoDB/Mongoose)
- **Front-end**: React Native (Expo) — Android, iOS, Web
- **Music API**: Deezer
- **Real-time**: Socket.IO (WebSocket gateways)

## Services

1. **Music Track Vote** — Live music chain with voting
2. **Music Control Delegation** — Music control delegation per device
3. **Music Playlist Editor** — Real-time multi-user playlist editing

## Project Structure

```
music-room/
├── back/          # NestJS modular monolith
├── front/         # React Native (Expo) mobile + web app
├── apiREST/       # API documentation (Swagger/OpenAPI)
├── Makefile       # Build & run targets
└── README.md
```

## Quick Start

```bash
# Install all dependencies
make install

# Start back-end (development)
make start-back

# Start front-end (development)
make start-front
```

## Environment Variables

Copy `.env.example` to `.env` in both `back/` and `front/` directories and fill in the required values.

```bash
cp back/.env.example back/.env
cp front/.env.example front/.env
```

## Tech Stack

| Layer          | Technology                          |
|----------------|-------------------------------------|
| Backend        | NestJS, TypeScript, Mongoose        |
| Database       | MongoDB                             |
| Auth           | JWT, Passport (Google, Facebook)    |
| Real-time      | Socket.IO                           |
| Mobile         | React Native (Expo)                 |
| Web            | Expo Web                            |
| Music API      | Deezer API                          |
| API Docs       | Swagger / OpenAPI                   |
| Testing        | Jest, Supertest, RNTL               |
| Load Testing   | k6 / Artillery                      |
| CI             | GitHub Actions                      |

## License

Private — 42 School Project
