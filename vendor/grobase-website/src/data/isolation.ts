// The 4 isolation models, selectable PER MOUNT (adapter-registry models.go).
export interface IsolationModel {
	id: string;
	name: string;
	how: string;
	cost: string;
	when: string;
}

export const ISOLATION_MODELS: IsolationModel[] = [
	{
		id: 'shared_rls',
		name: 'Shared RLS',
		how: 'One database, rows filtered by tenant via Postgres row-level security / owner-id scoping.',
		cost: 'Cheapest, densest',
		when: 'Many small tenants',
	},
	{
		id: 'schema_per_tenant',
		name: 'Schema per tenant',
		how: 'One database, a private schema per tenant (search_path isolation, per-tenant DDL).',
		cost: 'Medium',
		when: 'Noisy-neighbour isolation',
	},
	{
		id: 'db_per_tenant',
		name: 'Database per tenant',
		how: 'A dedicated database (or cluster) per tenant; distinct encrypted mount + DSN.',
		cost: 'Priciest, hardest walls',
		when: 'Regulated / enterprise SLA',
	},
	{
		id: 'tenant_owned',
		name: 'Tenant-owned',
		how: 'The tenant brings their own database. The mount is theirs alone — AES-256-GCM-encrypted DSN, no per-row scoping needed.',
		cost: 'Their infra, your API',
		when: 'Bring-your-own-database',
	},
];
