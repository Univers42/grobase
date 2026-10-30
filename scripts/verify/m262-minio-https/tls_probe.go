// tls_probe GETs each URL with Go's default client, which trusts SSL_CERT_DIR (gate m262,
// ADR 0030 MH5), and prints one line per URL: "status=<code>" or "error=<message>".
package main

import (
	"fmt"
	"net/http"
	"os"
	"time"
)

func main() {
	client := &http.Client{Timeout: 10 * time.Second}
	for _, url := range os.Args[1:] {
		resp, err := client.Get(url)
		if err != nil {
			fmt.Printf("error=%v\n", err)
			continue
		}
		_ = resp.Body.Close()
		fmt.Printf("status=%d\n", resp.StatusCode)
	}
}
