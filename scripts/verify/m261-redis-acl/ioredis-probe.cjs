// ioredis-probe.cjs is the m261 gate's ioredis client (the 5.11.0 src/package-lock.json
// resolves; outbox-relay's relay and saga coordinator dial with these options). It never
// prints a URL. A wrong password must be refused, not served as default; the rendered URL
// must log in as app, and that connection is then held so CLIENT LIST can count it.
const Redis = require(process.env.M261_IOREDIS);

const options = { lazyConnect: true, enableOfflineQueue: false, maxRetriesPerRequest: 1 };

// The first word of each 'error' event: connect() itself rejects with "Connection is
// closed." once the server refuses the AUTH, so the reason is only in the event.
const reasons = [];

async function whoami(name, extra) {
  const client = new Redis(process.env[name], { ...options, ...extra });
  client.on('error', (err) => reasons.push(String(err.message).split(' ')[0]));
  await client.connect();
  return { client, who: await client.call('ACL', 'WHOAMI') };
}

async function main() {
  try {
    const { client, who } = await whoami('M261_WRONG_URL', { retryStrategy: () => null });
    client.disconnect();
    console.log(`ioredis: FAIL wrong password served as ${who}`);
    process.exit(1);
  } catch (err) {
    const why = [String(err.message).split(' ')[0], ...reasons].join(', ');
    console.log(`ioredis: wrong password refused (${why})`);
  }
  const { who } = await whoami('M261_RIGHT_URL', {});
  if (who !== 'app') {
    console.log(`ioredis: FAIL rendered url answered ${who}`);
    process.exit(1);
  }
  console.log('ioredis: rendered url logged in as app, holding');
  setInterval(() => {}, 60_000);
}

main().catch((err) => {
  console.log(`ioredis: FAIL ${String(err.message).split(' ')[0]}`);
  process.exit(1);
});
