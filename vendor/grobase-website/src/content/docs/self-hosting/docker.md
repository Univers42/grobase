---
title: Run with Docker
description: Run Grobase as a container, persist its data, and wire your application to it — the path most self-hosted deployments take.
section: Self-hosting
order: 1
---

# Run with Docker

Beyond the single nano binary, Grobase ships as a container image. This is the
usual shape for a server deployment: persistent data, predictable resource limits,
and the same uniform API your application already calls.

## Start a container

```
docker run -d \
  --name grobase \
  -p 8090:8090 \
  -v grobase-data:/data \
  grobase serve --data /data
```

The named volume keeps your data across restarts and upgrades. The API is now
reachable on `http://localhost:8090`, identical to the binary.

## Configure with environment

Pass configuration as environment variables rather than baking it into the image:

```
docker run -d \
  --name grobase \
  -p 8090:8090 \
  -v grobase-data:/data \
  -e GROBASE_DATA=/data \
  grobase serve
```

See [Configuration](/docs/self-hosting/configuration/) for the full set of
variables, and keep secrets out of the command line and out of the image.

## Connect a database engine

The nano shape embeds its own datastore. To put Grobase in front of an existing
engine — PostgreSQL, MySQL, MongoDB and the rest — connect a **mount** pointing at
that engine. Your application code does not change: the uniform API hides which
engine sits behind the mount.

## Health and upgrades

Probe the server's health endpoint for orchestrator readiness checks, then upgrade
by pulling a new image and recreating the container against the same volume — your
data persists because it lives in the volume, not the container.

## Next steps

Tune the deployment in [Configuration](/docs/self-hosting/configuration/), then
choose the right capability set in [Tiers](/docs/self-hosting/tiers/).
