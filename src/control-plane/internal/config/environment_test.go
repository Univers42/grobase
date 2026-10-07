package config

import (
	"errors"
	"strings"
	"testing"
)

// isolateEnv blanks every variable LoadConfig consults so an ambient shell value
// cannot leak into a case, then applies the case's own overrides.
func isolateEnv(t *testing.T, set map[string]string) {
	t.Helper()
	for _, key := range []string{
		environmentKey, "DATABASE_URL", serviceTokenKey, "VAULT_ENC_KEY",
		"GOTRUE_JWT_SECRET", "JWT_SECRET", "SECURITY_MODE", "VAULT_ADDR", "VAULT_CREDENTIAL_SOURCE",
	} {
		t.Setenv(key, "")
	}
	for key, value := range set {
		t.Setenv(key, value)
	}
}

// TestParseEnvironment pins the GROBASE_ENV contract: unset/empty is local, the
// four schema values parse (whitespace ignored), everything else — including a
// wrong-case "PROD" — is rejected with an error that names the allowed set and
// never echoes the offending value.
func TestParseEnvironment(t *testing.T) {
	cases := []struct {
		name    string
		raw     string
		want    Environment
		wantErr bool
	}{
		{"unset defaults to local", "", Local, false},
		{"blank defaults to local", "   ", Local, false},
		{"local", "local", Local, false},
		{"dev", "dev", Dev, false},
		{"staging", "staging", Staging, false},
		{"prod", "prod", Prod, false},
		{"surrounding space ignored", " prod\n", Prod, false},
		{"unknown rejected", "production", "", true},
		{"wrong case fails closed", "PROD", "", true},
		{"abbreviation rejected", "stage", "", true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, err := ParseEnvironment(c.raw)
			if (err != nil) != c.wantErr {
				t.Fatalf("ParseEnvironment(%q) err=%v, wantErr=%v", c.raw, err, c.wantErr)
			}
			if got != c.want {
				t.Fatalf("ParseEnvironment(%q) = %q, want %q", c.raw, got, c.want)
			}
			if c.wantErr && !errors.Is(err, ErrUnknownEnvironment) {
				t.Fatalf("ParseEnvironment(%q) err=%v, want ErrUnknownEnvironment", c.raw, err)
			}
		})
	}
}

// TestParseEnvironmentErrorNamesSetNotValue asserts the rejection lists the
// allowed values and does not repeat what the operator typed.
func TestParseEnvironmentErrorNamesSetNotValue(t *testing.T) {
	const typed = "zz-typed-value"
	_, err := ParseEnvironment(typed)
	if err == nil {
		t.Fatal("unknown environment must be rejected")
	}
	for _, allowed := range []string{"local", "dev", "staging", "prod"} {
		if !strings.Contains(err.Error(), allowed) {
			t.Errorf("error %q does not name allowed value %q", err, allowed)
		}
	}
	if strings.Contains(err.Error(), typed) {
		t.Errorf("error %q echoes the rejected value", err)
	}
}

// TestEnvironmentStrict pins which environments turn a missing secret into a
// refusal to boot.
func TestEnvironmentStrict(t *testing.T) {
	cases := []struct {
		env  Environment
		want bool
	}{
		{Local, false}, {Dev, false}, {Staging, true}, {Prod, true},
	}
	for _, c := range cases {
		if got := c.env.Strict(); got != c.want {
			t.Errorf("%q.Strict() = %v, want %v", c.env, got, c.want)
		}
	}
}

// TestRequiredSecretsPerPrefix pins the per-binary secret set, so a renamed
// prefix or a dropped entry cannot silently weaken staging/prod.
func TestRequiredSecretsPerPrefix(t *testing.T) {
	cases := []struct {
		prefix string
		want   []string
	}{
		{"ADAPTER_REGISTRY", []string{"VAULT_ENC_KEY"}},
		{"TENANT_CONTROL", []string{"GOTRUE_JWT_SECRET or JWT_SECRET"}},
		{"ORCHESTRATOR", nil},
		{"FUNCTION_SCHEDULER", nil},
		{"WEBHOOK_DISPATCHER", nil},
		{"TESTSVC", nil},
	}
	for _, c := range cases {
		t.Run(c.prefix, func(t *testing.T) {
			var got []string
			for _, group := range requiredSecrets(c.prefix) {
				got = append(got, group.name())
			}
			if strings.Join(got, "|") != strings.Join(c.want, "|") {
				t.Fatalf("requiredSecrets(%q) = %v, want %v", c.prefix, got, c.want)
			}
		})
	}
}

// TestLoadConfigRequiredSecretsByEnvironment is the fail-fast matrix: the same
// missing secret is a refusal in staging/prod and tolerated in local/dev, a
// satisfied group (either JWT key) boots, and an unknown GROBASE_ENV never boots.
func TestLoadConfigRequiredSecretsByEnvironment(t *testing.T) {
	base := map[string]string{"DATABASE_URL": "postgres://u:p@db/x", serviceTokenKey: "a-real-service-token"}
	with := func(extra map[string]string) map[string]string {
		out := map[string]string{}
		for k, v := range base {
			out[k] = v
		}
		for k, v := range extra {
			out[k] = v
		}
		return out
	}
	cases := []struct {
		name    string
		prefix  string
		env     map[string]string
		wantErr error
		wantKey string
	}{
		{"adapter-registry prod without VAULT_ENC_KEY", "ADAPTER_REGISTRY", with(map[string]string{"GROBASE_ENV": "prod"}), ErrMissingConfig, "VAULT_ENC_KEY"},
		{"adapter-registry staging without VAULT_ENC_KEY", "ADAPTER_REGISTRY", with(map[string]string{"GROBASE_ENV": "staging"}), ErrMissingConfig, "VAULT_ENC_KEY"},
		{"adapter-registry prod with VAULT_ENC_KEY", "ADAPTER_REGISTRY", with(map[string]string{"GROBASE_ENV": "prod", "VAULT_ENC_KEY": "k"}), nil, ""},
		{"adapter-registry local tolerates it", "ADAPTER_REGISTRY", with(map[string]string{"GROBASE_ENV": "local"}), nil, ""},
		{"adapter-registry dev tolerates it", "ADAPTER_REGISTRY", with(map[string]string{"GROBASE_ENV": "dev"}), nil, ""},
		{"adapter-registry unset env tolerates it", "ADAPTER_REGISTRY", with(nil), nil, ""},
		{"tenant-control prod without a JWT secret", "TENANT_CONTROL", with(map[string]string{"GROBASE_ENV": "prod"}), ErrMissingConfig, "GOTRUE_JWT_SECRET or JWT_SECRET"},
		{"tenant-control prod with GOTRUE_JWT_SECRET", "TENANT_CONTROL", with(map[string]string{"GROBASE_ENV": "prod", "GOTRUE_JWT_SECRET": "s"}), nil, ""},
		{"tenant-control prod with JWT_SECRET", "TENANT_CONTROL", with(map[string]string{"GROBASE_ENV": "prod", "JWT_SECRET": "s"}), nil, ""},
		{"tenant-control local tolerates no JWT secret", "TENANT_CONTROL", with(map[string]string{"GROBASE_ENV": "local"}), nil, ""},
		{"orchestrator prod needs only the common set", "ORCHESTRATOR", with(map[string]string{"GROBASE_ENV": "prod"}), nil, ""},
		{"function-scheduler prod needs only the common set", "FUNCTION_SCHEDULER", with(map[string]string{"GROBASE_ENV": "prod"}), nil, ""},
		{"webhook-dispatcher prod keeps VAULT_ENC_KEY optional", "WEBHOOK_DISPATCHER", with(map[string]string{"GROBASE_ENV": "prod"}), nil, ""},
		{"unknown environment never boots", "ORCHESTRATOR", with(map[string]string{"GROBASE_ENV": "production"}), ErrUnknownEnvironment, ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			isolateEnv(t, c.env)
			_, err := LoadConfig(c.prefix)
			if !errors.Is(err, c.wantErr) {
				t.Fatalf("LoadConfig(%q) err=%v, want errors.Is %v", c.prefix, err, c.wantErr)
			}
			if c.wantKey != "" && !strings.Contains(err.Error(), c.wantKey) {
				t.Fatalf("error %q does not name %q", err, c.wantKey)
			}
		})
	}
}

// TestLoadConfigAggregatesMissingKeys proves every missing key is reported in
// one error, in strict and non-strict environments alike.
func TestLoadConfigAggregatesMissingKeys(t *testing.T) {
	cases := []struct {
		name     string
		prefix   string
		env      map[string]string
		wantKeys []string
	}{
		{
			"prod: database, token and jwt all missing", "TENANT_CONTROL",
			map[string]string{"GROBASE_ENV": "prod"},
			[]string{"DATABASE_URL", serviceTokenKey, "GOTRUE_JWT_SECRET or JWT_SECRET"},
		},
		{
			"staging: token and vault key missing", "ADAPTER_REGISTRY",
			map[string]string{"GROBASE_ENV": "staging", "DATABASE_URL": "postgres://u:p@db/x"},
			[]string{serviceTokenKey, "VAULT_ENC_KEY"},
		},
		{
			"local: database and token both reported", "ORCHESTRATOR",
			map[string]string{"GROBASE_ENV": "local"},
			[]string{"DATABASE_URL", serviceTokenKey},
		},
		{
			"prod: the placeholder token counts as missing", "ORCHESTRATOR",
			map[string]string{"GROBASE_ENV": "prod", "DATABASE_URL": "postgres://u:p@db/x", serviceTokenKey: weakServiceToken},
			[]string{serviceTokenKey},
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			isolateEnv(t, c.env)
			_, err := LoadConfig(c.prefix)
			if !errors.Is(err, ErrMissingConfig) {
				t.Fatalf("LoadConfig(%q) err=%v, want ErrMissingConfig", c.prefix, err)
			}
			for _, key := range c.wantKeys {
				if !strings.Contains(err.Error(), key) {
					t.Errorf("error %q does not name %q", err, key)
				}
			}
		})
	}
}

// TestLoadConfigErrorNeverEchoesValues sets real-looking secrets next to a
// missing one and requires that none of the configured values reaches the error.
func TestLoadConfigErrorNeverEchoesValues(t *testing.T) {
	secrets := map[string]string{
		"DATABASE_URL":  "postgres://svc:hunter2-db-password@db/x",
		serviceTokenKey: "tok-hunter2-service-token",
		"JWT_SECRET":    "hunter2-jwt-secret",
	}
	isolateEnv(t, map[string]string{
		"GROBASE_ENV": "prod", "DATABASE_URL": secrets["DATABASE_URL"],
		serviceTokenKey: secrets[serviceTokenKey], "JWT_SECRET": secrets["JWT_SECRET"],
	})
	_, err := LoadConfig("ADAPTER_REGISTRY")
	if !errors.Is(err, ErrMissingConfig) {
		t.Fatalf("err=%v, want ErrMissingConfig (VAULT_ENC_KEY is unset)", err)
	}
	for key, value := range secrets {
		if strings.Contains(err.Error(), value) || strings.Contains(err.Error(), "hunter2") {
			t.Errorf("error leaks the value of %s: %q", key, err)
		}
	}
}

// TestLoadConfigRecordsEnvironment checks the parsed identity reaches Config.
func TestLoadConfigRecordsEnvironment(t *testing.T) {
	cases := []struct {
		raw  string
		want Environment
	}{
		{"", Local}, {"dev", Dev}, {"staging", Staging}, {"prod", Prod},
	}
	for _, c := range cases {
		t.Run("GROBASE_ENV="+c.raw, func(t *testing.T) {
			isolateEnv(t, map[string]string{
				"GROBASE_ENV": c.raw, "DATABASE_URL": "postgres://u:p@db/x",
				serviceTokenKey: "a-real-service-token",
			})
			cfg, err := LoadConfig("ORCHESTRATOR")
			if err != nil {
				t.Fatalf("LoadConfig err=%v", err)
			}
			if cfg.Environment != c.want {
				t.Fatalf("Environment = %q, want %q", cfg.Environment, c.want)
			}
		})
	}
}
