// The 8 engines behind the one /query/v1 API (Rust data plane,
// data-plane-pool crate features — see mini-baas-infra).
export interface Engine {
	id: string;
	name: string;
	colorVar: string;
	note: string;
}

export const ENGINES: Engine[] = [
	{ id: 'postgres', name: 'PostgreSQL', colorVar: '--gb-engine-postgres', note: 'flagship OLTP, RLS, logical-replication CDC' },
	{ id: 'mysql', name: 'MySQL / MariaDB', colorVar: '--gb-engine-mysql', note: 'pure-Rust driver, full CRUD' },
	{ id: 'mongodb', name: 'MongoDB', colorVar: '--gb-engine-mongodb', note: 'documents, change-stream CDC' },
	{ id: 'sqlite', name: 'SQLite', colorVar: '--gb-engine-sqlite', note: 'embedded in-process — zero extra RAM' },
	{ id: 'redis', name: 'Redis', colorVar: '--gb-engine-redis', note: 'cache / session / KV workloads' },
	{ id: 'cockroach', name: 'CockroachDB', colorVar: '--gb-engine-cockroach', note: 'distributed SQL, Postgres dialect' },
	{ id: 'mssql', name: 'MSSQL', colorVar: '--gb-engine-mssql', note: 'TDS protocol, pure-Rust tiberius' },
	{ id: 'http', name: 'HTTP', colorVar: '--gb-engine-http', note: 'federate any JSON API as a mount' },
];
