package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
)

func deleteTenant(client *http.Client, base, token, slug string) {
	req, _ := http.NewRequest(http.MethodDelete, base+"/v1/tenants/"+slug, nil)
	serviceHeaders(req, token, "")
	if resp, err := client.Do(req); err == nil {
		_, _ = io.Copy(io.Discard, resp.Body)
		resp.Body.Close()
	}
}

func teardown(client *http.Client, base, token, outPath string) error {
	f, err := os.Open(outPath)
	if err != nil {
		return err
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 1<<20), 1<<20)
	n := 0
	for sc.Scan() {
		var rec record
		if json.Unmarshal(sc.Bytes(), &rec) != nil || rec.Slug == "" {
			continue
		}
		deleteTenant(client, base, token, rec.Slug)
		n++
		if n%500 == 0 {
			fmt.Printf("  teardown %d…\n", n)
		}
	}
	fmt.Printf("teardown complete: %d tenants soft-deleted\n", n)
	return sc.Err()
}
