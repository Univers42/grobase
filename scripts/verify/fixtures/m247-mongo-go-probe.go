// m247 leg D: the orchestrator's mongo dial without booting the orchestrator, whose Init
// needs postgres and redis before it reaches mongo (ADR 0025, M7). Built against
// src/control-plane/go.mod, so it links the mongo-driver the orchestrator ships, and dials
// the way outboxrelay.connectMongo does: ApplyURI, 5 s server selection, then a ping.
// The URI comes from M247_MONGO_URI and is never printed.
package main

import (
	"context"
	"fmt"
	"os"
	"time"

	"go.mongodb.org/mongo-driver/mongo"
	"go.mongodb.org/mongo-driver/mongo/options"
	"go.mongodb.org/mongo-driver/version"
)

func main() {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	client, err := mongo.Connect(ctx, options.Client().
		ApplyURI(os.Getenv("M247_MONGO_URI")).
		SetServerSelectionTimeout(5*time.Second))
	if err == nil {
		err = client.Ping(ctx, nil)
		_ = client.Disconnect(context.Background())
	}
	if err != nil {
		fmt.Printf("mongo-driver %s refused: %v\n", version.Driver, err)
		os.Exit(1)
	}
	fmt.Printf("mongo-driver %s: mongo projector connected\n", version.Driver)
}
