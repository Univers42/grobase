// Example edge function. Default export receives an InvokeInput and returns an
// InvokeResult (see wiki/back/08_edge_functions.md).
//
//   interface InvokeInput  { tenant_id, method, headers, body }
//   interface InvokeResult { status?, body?, contentType? }
//
// Upload via:
//   curl -X POST http://localhost:3060/v1/functions \
//        -H "X-Baas-Tenant-Id: t-demo" \
//        -d '{"name":"hello","code":"<contents of this file>"}'
//
// Invoke via:
//   curl -X POST http://localhost:3060/v1/functions/hello/invoke \
//        -H "X-Baas-Tenant-Id: t-demo" -d '{"name":"world"}'

export default async function exampleFunction(input: {
  tenant_id: string;
  method: string;
  headers: Record<string, string>;
  body: unknown;
}) {
  const name = (input.body as { name?: string } | null)?.name ?? "anon";
  return {
    status: 200,
    body: { greeting: `hello, ${name}`, tenant: input.tenant_id, ts: Date.now() },
  };
}
