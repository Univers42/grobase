# Docker quick cheatsheet

## Inspect services and status
- Show Compose services and current status:
```bash
docker compose ps
# or
docker-compose ps
```

- Show all containers (running and stopped) and the IMAGE column:
```bash
docker ps -a
```

- List local images (to see Alpine and your built image):
```bash
docker image ls
docker image ls alpine
```

- View which image a container is using:
```bash
docker inspect vite_gourmand_backend --format '{{.Config.Image}}'
```

- View logs (follow output) for a service/container:
```bash
docker compose logs -f backend
# or
docker logs -f vite_gourmand_backend
```

- Open a shell inside a running container:
```bash
docker exec -it vite_gourmand_backend sh
```

- List volumes and inspect:
```bash
docker volume ls
docker volume inspect vite_gourmand_db_data
```

Tips:
- If `docker compose ps` shows "Up" the service is running.
- If `docker ps` shows IMAGE column equals "node:20-alpine" then that container uses an Alpine-based Node image.

## What is an image?
An image is a read-only template (filesystem layers + metadata) used to create containers. Images are built (docker build) or pulled (docker pull). Examples from your project:
- Official images pulled: `postgres:16-alpine`, `mongo:7.0`, `node:20-alpine`, `mongo-express:1.0.0-alpha`
- Local image built from your Dockerfile: `vite-gourmand-backend`

Images are immutable; you create containers from them.

## What is a container?
A container is a runnable instance of an image. It has:
- A writable layer for runtime changes
- Its own process(es), networking, and filesystem view
- Lifecycle controls (start, stop, restart, remove)

Examples in your environment (instances of images):
- `vite_gourmand_postgres` — container running `postgres:16-alpine`
- `vite_gourmand_mongo` — container running `mongo:7.0`
- `vite_gourmand_backend` — container running your local `vite-gourmand-backend` image
- `mongo_express` — container running `mongo-express:1.0.0-alpha`

## Related concepts
- Volumes: persist data outside container writable layer (e.g., Postgres data volume).
- Networks: allow containers to communicate (Compose creates a network; services can reach each other by service name).
- Build vs Run: build an image, then run it to create containers.

## Common commands recap
```bash
docker image ls
docker ps -a
docker compose ps
docker inspect <container> --format '{{.Config.Image}}'
docker logs -f <container>
docker exec -it <container> sh
docker volume ls
docker volume inspect <volume>
```

## Verify DB access & migrations

- Mongo shell command (correct for your compose):
  - docker exec -it vite_gourmand_mongo mongosh -u mongo_user -p mongo_pass --authenticationDatabase admin
  - Reason: MONGO_INITDB_ROOT_USERNAME / MONGO_INITDB_ROOT_PASSWORD create the root user in the admin database; use --authenticationDatabase admin.

- DATABASE_URL provided to backend (correct):
  - In docker-compose.yml the backend environment contains:
    DATABASE_URL: postgresql://user:password@postgres:5432/vite_gourmand
  - That host name "postgres" resolves to the postgres container only from inside the Compose network (i.e., from other containers).

- Migrations: host vs container
  - From host (Windows): use localhost:5432 (psql or Prisma CLI) because host sees the published port.
  - Inside container (recommended for Compose workflows): run migrations in the backend container so service hostnames work, e.g.
    docker compose exec backend npx prisma migrate deploy

