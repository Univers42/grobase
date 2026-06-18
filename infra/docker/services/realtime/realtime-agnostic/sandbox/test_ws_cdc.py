# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    test_ws_cdc.py                                     :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/05/18 21:19:15 by dlesieur          #+#    #+#              #
#    Updated: 2026/05/18 21:19:15 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

#!/usr/bin/env python3
"""End-to-end test: WebSocket client subscribes, then PG/Mongo CDC events are triggered."""
import asyncio
import json
import sys

async def main():
    import websockets

    print("=== SyncSpace E2E CDC Test ===\n")

    # Connect two clients
    ws1 = await websockets.connect("ws://localhost:4002/ws")
    ws2 = await websockets.connect("ws://localhost:4002/ws")

    # Auth both
    await ws1.send(json.dumps({"type": "AUTH", "token": "user-alice"}))
    await ws2.send(json.dumps({"type": "AUTH", "token": "user-bob"}))
    r1 = await asyncio.wait_for(ws1.recv(), timeout=3)
    r2 = await asyncio.wait_for(ws2.recv(), timeout=3)
    print(f"Alice AUTH: {r1}")
    print(f"Bob   AUTH: {r2}")

    # Subscribe both to pg/** and mongo/**
    for ws, name in [(ws1, "Alice"), (ws2, "Bob")]:
        await ws.send(json.dumps({"type": "SUBSCRIBE", "sub_id": "pg-cdc", "topic": "pg/**"}))
        r = await asyncio.wait_for(ws.recv(), timeout=3)
        print(f"{name} PG SUB: {r}")

        await ws.send(json.dumps({"type": "SUBSCRIBE", "sub_id": "mongo-cs", "topic": "mongo/**"}))
        r = await asyncio.wait_for(ws.recv(), timeout=3)
        print(f"{name} MONGO SUB: {r}")

    print("\n--- Triggering PostgreSQL INSERT (via docker exec) ---")
    proc = await asyncio.create_subprocess_exec(
        "docker", "compose", "exec", "-T", "postgres", "psql", "-U", "syncspace", "-c",
        "INSERT INTO cards (id, list_id, title, description, position, created_by) "
        "VALUES ('card-e2e-test', 'list-backlog', 'E2E Test Card', 'Created by test script', 99, 'user-alice');",
        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
    )
    await proc.communicate()
    print("INSERT done, waiting for events...")

    # Collect events from both clients
    pg_events = []
    for ws, name in [(ws1, "Alice"), (ws2, "Bob")]:
        try:
            msg = await asyncio.wait_for(ws.recv(), timeout=5)
            pg_events.append((name, msg))
            print(f"  {name} received PG event: {msg[:120]}...")
        except asyncio.TimeoutError:
            print(f"  {name}: NO PG event (timeout)")

    print("\n--- Triggering MongoDB INSERT (via docker exec) ---")
    proc = await asyncio.create_subprocess_exec(
        "docker", "compose", "exec", "-T", "mongo", "mongosh", "syncspace", "--quiet", "--eval",
        "db.chat_messages.insertOne({channelId:'ch-general',userId:'user-bob',username:'Bob',"
        "content:'E2E test message from Mongo!',createdAt:new Date()})",
        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
    )
    await proc.communicate()
    print("INSERT done, waiting for events...")

    mongo_events = []
    for ws, name in [(ws1, "Alice"), (ws2, "Bob")]:
        try:
            msg = await asyncio.wait_for(ws.recv(), timeout=5)
            mongo_events.append((name, msg))
            print(f"  {name} received Mongo event: {msg[:120]}...")
        except asyncio.TimeoutError:
            print(f"  {name}: NO Mongo event (timeout)")

    await ws1.close()
    await ws2.close()

    print("\n=== RESULTS ===")
    print(f"PG CDC events received:    {len(pg_events)}/2")
    print(f"Mongo CDC events received: {len(mongo_events)}/2")

    if len(pg_events) == 2 and len(mongo_events) == 2:
        print("\n✅ ALL TESTS PASSED — Full CDC pipeline working!")
        return 0
    else:
        print("\n❌ SOME TESTS FAILED")
        return 1

if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
