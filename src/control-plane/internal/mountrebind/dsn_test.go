package mountrebind

import "testing"

func testTargets() []Target {
	return []Target{
		{Engine: "postgresql", Schemes: []string{"postgres", "postgresql"}, Hosts: []string{"postgres", "mini-baas-postgres"}, Port: 5432, User: "postgres", Password: "n3w/p@ss:word"},
		{Engine: "mysql", Schemes: []string{"mysql"}, Hosts: []string{"mysql"}, Port: 3306, User: "root", Password: "rootpw"},
		{Engine: "mssql", Schemes: []string{"mssql", "sqlserver"}, Hosts: []string{"mssql"}, Port: 1433, User: "sa", Password: "Str0ng!pw"},
		{Engine: "redis", Schemes: []string{"redis"}, Hosts: []string{"redis"}, Port: 6379, User: "", Password: "redispw"},
	}
}

func TestRewriteDSN(t *testing.T) {
	cases := []struct {
		name, engine, dsn, want string
		outcome                 Outcome
	}{
		{"pg platform login, password percent-encoded", "postgresql", "postgresql://postgres:old@postgres:5432/agency", "postgresql://postgres:n3w%2Fp%40ss%3Aword@postgres:5432/agency", Rebound},
		{"pg default port counts as 5432", "postgresql", "postgres://postgres:old@mini-baas-postgres/commerce?sslmode=disable", "postgres://postgres:n3w%2Fp%40ss%3Aword@mini-baas-postgres/commerce?sslmode=disable", Rebound},
		{"pg external host left alone", "postgresql", "postgresql://postgres:old@db.example.com:5432/x", "postgresql://postgres:old@db.example.com:5432/x", Unmatched},
		{"pg other user left alone", "postgresql", "postgresql://app:old@postgres:5432/x", "postgresql://app:old@postgres:5432/x", Unmatched},
		{"pg other port left alone", "postgresql", "postgresql://postgres:old@postgres:6543/x", "postgresql://postgres:old@postgres:6543/x", Unmatched},
		{"mysql platform login", "mysql", "mysql://root:old@mysql:3306/ops", "mysql://root:rootpw@mysql:3306/ops", Rebound},
		{"mssql written raw", "mssql", "mssql://sa:Old!pw@mssql:1433/master", "mssql://sa:Str0ng!pw@mssql:1433/master", Rebound},
		{"mssql without port or db", "mssql", "sqlserver://sa:x@mssql", "sqlserver://sa:Str0ng!pw@mssql", Rebound},
		{"redis password-only login", "redis", "redis://:old@redis:6379/0", "redis://:redispw@redis:6379/0", Rebound},
		{"sqlite carries no credentials", "sqlite", "sqlite:///data/x.db", "sqlite:///data/x.db", NoCredentials},
		{"engine without a target", "mongodb", "mongodb://root:old@mongo:27017/a", "mongodb://root:old@mongo:27017/a", NoTarget},
		{"unparsable URL", "postgresql", "not a url", "not a url", Unparsable},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, outcome := RewriteDSN(c.engine, c.dsn, testTargets())
			if got != c.want || outcome != c.outcome {
				t.Fatalf("RewriteDSN(%q) = %q, %q; want %q, %q", c.dsn, got, outcome, c.want, c.outcome)
			}
		})
	}
}

func TestRewriteDSNRefusesMSSQLSplitCharacters(t *testing.T) {
	targets := testTargets()
	targets[2].Password = "p@ss"
	dsn := "mssql://sa:old@mssql:1433/master"
	got, outcome := RewriteDSN("mssql", dsn, targets)
	if got != dsn || outcome != Refused {
		t.Fatalf("got %q, %q; want the DSN unchanged and %q", got, outcome, Refused)
	}
}
