package adapterregistry

import "testing"

// TestIsAllowedEngine_Membership pins the EXACT membership of the former
// engine-allowlist map (now a switch-predicate func). Every formerly-allowed
// engine must return true; a representative quarantined/unknown engine must
// return false. A drift here is the precise bug the de-globalization could
// introduce (a case dropped or mistyped when the map became a switch).
func TestIsAllowedEngine_Membership(t *testing.T) {
	allowed := []string{
		"postgresql", "cockroachdb", "mysql", "mariadb", "mongodb",
		"redis", "sqlite", "mssql", "http",
	}
	for _, e := range allowed {
		if !isAllowedEngine(e) {
			t.Errorf("isAllowedEngine(%q) = false, want true (allowed engine dropped)", e)
		}
	}
	// The quarantined stubs (never Rust-served) plus garbage must be refused.
	rejected := []string{
		"oracle", "jdbc", "cassandra", "neo4j", "elasticsearch", "qdrant",
		"influx", "", "POSTGRESQL", "postgres", " postgresql",
	}
	for _, e := range rejected {
		if isAllowedEngine(e) {
			t.Errorf("isAllowedEngine(%q) = true, want false (unserved engine accepted)", e)
		}
	}
}

// TestIsAllowedIsolation_Membership pins the EXACT membership of the former
// isolation-allowlist map (now a switch). Every isolation strategy the data
// plane understands must be true; an unknown one false.
func TestIsAllowedIsolation_Membership(t *testing.T) {
	allowed := []string{"shared_rls", "schema_per_tenant", "db_per_tenant", "tenant_owned"}
	for _, iso := range allowed {
		if !isAllowedIsolation(iso) {
			t.Errorf("isAllowedIsolation(%q) = false, want true (allowed isolation dropped)", iso)
		}
	}
	rejected := []string{"", "shared", "rls", "per_tenant", "SHARED_RLS", "owner_scoped", "none"}
	for _, iso := range rejected {
		if isAllowedIsolation(iso) {
			t.Errorf("isAllowedIsolation(%q) = true, want false (unknown isolation accepted)", iso)
		}
	}
}
