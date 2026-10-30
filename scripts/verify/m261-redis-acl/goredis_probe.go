// goredis_probe.go is the m261 gate's go-redis client (the v9 the control plane pins,
// built against src/control-plane's go.mod; webhook-dispatcher, orchestrator and
// tenant-control dial redis through redis.ParseURL like this). It never prints a URL.
//
// It proves three things against the REDIS_ACL overlay: the credential-free
// redis://redis:6379 a tenant mount registers is served as default (stage 1, RA8); a
// wrong password is refused rather than served as default; the rendered URL logs in as
// app. `hold` then keeps that connection open so the gate's CLIENT LIST can count it.
package main

import (
	"context"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/redis/go-redis/v9"
)

func whoami(ctx context.Context, client *redis.Client) (string, error) {
	return client.Do(ctx, "ACL", "WHOAMI").Text()
}

func dial(name string) *redis.Client {
	opt, err := redis.ParseURL(os.Getenv(name))
	if err != nil {
		fmt.Printf("go-redis: %s does not parse\n", name)
		os.Exit(1)
	}
	return redis.NewClient(opt)
}

// once dials the URL in env var name, asks who it is and closes the client.
func once(ctx context.Context, name string) (string, error) {
	client := dial(name)
	defer client.Close()
	return whoami(ctx, client)
}

// check runs the credential-free and wrong-password dials. It is its own process: after
// WRONGPASS, go-redis 9.20.0 kept that socket open as user=default (cmd=auth) past
// client.Close() while the process lived (measured by m261), which CLIENT LIST would count.
func check(ctx context.Context) {
	if who, err := once(ctx, "M261_PLAIN_URL"); err != nil || who != "default" {
		fmt.Printf("go-redis: FAIL credential-free url answered %q (err %v)\n", who, err)
		os.Exit(1)
	}
	fmt.Println("go-redis: credential-free url served as default (RA8)")
	if who, err := once(ctx, "M261_WRONG_URL"); err == nil {
		fmt.Printf("go-redis: FAIL wrong password served as %q\n", who)
		os.Exit(1)
	} else {
		fmt.Printf("go-redis: wrong password refused (%s)\n", strings.Fields(err.Error())[0])
	}
}

func hold(ctx context.Context) {
	held := dial("M261_RIGHT_URL")
	if who, err := whoami(ctx, held); err != nil || who != "app" {
		fmt.Printf("go-redis: FAIL rendered url answered %q (err %v)\n", who, err)
		os.Exit(1)
	}
	fmt.Println("go-redis: rendered url logged in as app, holding")
	time.Sleep(10 * time.Minute)
}

func main() {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	if len(os.Args) > 1 && os.Args[1] == "hold" {
		hold(ctx)
		return
	}
	check(ctx)
}
