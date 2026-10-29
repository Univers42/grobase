package adapterregistry

import (
	"encoding/json"
	"strings"
	"testing"
)

const canary = "Canary-pw_7f3a"

func TestDescribeDSN(t *testing.T) {
	cases := []struct {
		engine, dsn string
		want        dsnFacts
	}{
		{
			"postgresql", "postgresql://app:" + canary + "@db.example.com:6543/shop?sslmode=verify-full",
			dsnFacts{location: locationNetwork, host: "db.example.com", port: 6543, database: "shop", tls: "verify"},
		},
		{
			"postgresql", "postgresql://postgres:" + canary + "@postgres:5432/tenant_a",
			dsnFacts{location: locationPlatform, database: "tenant_a", tls: "default"},
		},
		{
			"cockroachdb", "postgresql://root@10.0.3.4:26257/defaultdb?sslmode=disable",
			dsnFacts{location: locationPlatform, database: "defaultdb", tls: "off"},
		},
		{
			"mssql", "mssql://sa:p@ss" + canary + "@sql.acme.io/erp",
			dsnFacts{location: locationUnknown, tls: tlsUnknown},
		},
		{
			"mysql", "mysql://u:" + canary + "@mysql.acme.io/orders?ssl-mode=REQUIRED",
			dsnFacts{location: locationNetwork, host: "mysql.acme.io", database: "orders", tls: "on"},
		},
		{
			"mongodb", "mongodb://u:" + canary + "@m1.acme.io:27017,m2.acme.io:27017/crm?tls=true&tlsInsecure=true",
			dsnFacts{location: locationNetwork, host: "m1.acme.io", port: 27017, database: "crm", tls: "insecure"},
		},
		{
			"redis", "rediss://:" + canary + "@cache.acme.io:6380/0",
			dsnFacts{location: locationNetwork, host: "cache.acme.io", port: 6380, database: "0", tls: "on"},
		},
		{
			"redis", "rediss://cache.acme.io/0#insecure",
			dsnFacts{location: locationNetwork, host: "cache.acme.io", database: "0", tls: "insecure"},
		},
		{
			"mssql", "mssql://sa:" + canary + "@sql.acme.io:1433/erp?encrypt=strict",
			dsnFacts{location: locationNetwork, host: "sql.acme.io", port: 1433, database: "erp", tls: "verify"},
		},
		{
			"mssql", "mssql://sa:" + canary + "@mssql:1433?encrypt=false",
			dsnFacts{location: locationPlatform, tls: "off"},
		},
		{
			"sqlite", "sqlite:///var/lib/mini-baas/" + "abc.db",
			dsnFacts{location: locationFile, file: "abc.db", tls: "n/a"},
		},
		{"sqlite", "sqlite::memory:", dsnFacts{location: locationMemory, tls: "n/a"}},
		{"http", "https://api.acme.io/v2", dsnFacts{location: locationNetwork, host: "api.acme.io", tls: "on"}},
		{
			"dynamodb", "dynamodb://dynamodb-local:8000?region=eu-west-1",
			dsnFacts{location: locationPlatform, tls: "default"},
		},
		{"postgresql", "host=db password=" + canary, dsnFacts{location: locationUnknown, tls: tlsUnknown}},
		{
			"postgresql", "postgresql://u:" + canary + "@" + strings.ToLower(canary) + ".acme.io/" + canary,
			dsnFacts{location: locationNetwork, host: strings.ToLower(canary) + ".acme.io", tls: "default"},
		},
	}
	for _, c := range cases {
		if got := describeDSN(c.engine, c.dsn); got != c.want {
			t.Errorf("describeDSN(%s, %q) = %+v, want %+v", c.engine, c.dsn, got, c.want)
		}
	}
}

// The wire form is the guarantee the UI relies on: no DSN form puts the password, the user
// or the raw DSN into the descriptor JSON.
func TestDescriptorJSONCarriesNoCredential(t *testing.T) {
	dsns := map[string]string{
		"postgresql": "postgresql://owner:" + canary + "@db.example.com/" + canary,
		"mysql":      "mysql://owner:" + canary + "@" + canary + ".example.com/app",
		"mongodb":    "mongodb://owner:" + canary + "@m.example.com/app?authSource=" + canary,
		"mssql":      "mssql://owner:" + canary + "@sql.example.com/" + canary,
		"redis":      "redis://owner:" + canary + "@r.example.com/0",
		"sqlite":     "sqlite:///data/" + canary + "/app.db",
	}
	for engine, dsn := range dsns {
		d := MountDescriptor{Engine: engine}.withFacts(describeDSN(engine, dsn))
		raw, err := json.Marshal(d)
		if err != nil {
			t.Fatal(err)
		}
		for _, banned := range []string{canary, "owner", dsn} {
			if strings.Contains(string(raw), banned) {
				t.Errorf("%s descriptor %s carries %q", engine, raw, banned)
			}
		}
	}
}

func TestIsPlatformHost(t *testing.T) {
	for host, want := range map[string]bool{
		"postgres": true, "localhost": true, "127.0.0.1": true, "::1": true, "192.168.1.9": true,
		"100.101.2.3": true, "db.internal": true, "box.local": true, "172.20.0.4": true,
		"db.example.com": false, "8.8.8.8": false, "2001:4860::8888": false,
	} {
		if got := isPlatformHost(host); got != want {
			t.Errorf("isPlatformHost(%q) = %v, want %v", host, got, want)
		}
	}
}
