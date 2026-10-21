import { buildApp } from './app.js';
const port = Number(process.env.PORT ?? 8080);
if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error('Invalid PORT');
const app = buildApp({ dbPath: process.env.DB_PATH ?? './data/relay.sqlite' });
for (const signal of ['SIGINT', 'SIGTERM'] as const) process.once(signal, () => { void app.close(); });
try {
  await app.listen({ port, host: '0.0.0.0' });
  console.log(`Relay listening on port ${port}`);
} catch (error) {
  console.error(error);
  await app.close();
  process.exitCode = 1;
}
