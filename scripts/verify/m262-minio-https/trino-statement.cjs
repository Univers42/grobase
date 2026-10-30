// Runs each SQL argument through Trino's /v1/statement protocol (the image ships no CLI) and
// prints "<state> rows=<json>" or "<state> cert-path=<bool> <message>" per statement (gate m262).
const head = { 'X-Trino-User': 'm262' };
const next = async (uri, init) => (await fetch(uri, { ...init, headers: head })).json();
const run = async (sql) => {
  let r = await next('http://trino:8080/v1/statement', { method: 'POST', body: sql });
  const rows = [];
  while (r.nextUri) {
    if (r.data) rows.push(...r.data);
    await new Promise((done) => setTimeout(done, 200));
    r = await next(r.nextUri);
  }
  if (r.data) rows.push(...r.data);
  if (!r.error) return `${r.stats.state} rows=${JSON.stringify(rows)}`;
  const certPath = JSON.stringify(r.error.failureInfo || {}).includes('SunCertPathBuilderException');
  return `${r.stats.state} cert-path=${certPath} ${r.error.message.slice(0, 120)}`;
};
(async () => {
  for (const sql of process.argv.slice(2)) console.log(await run(sql));
})().catch((e) => {
  console.log('ERR', e.message);
  process.exit(1);
});
