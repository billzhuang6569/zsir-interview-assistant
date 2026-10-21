import Fastify from 'fastify';

export function buildApp() {
  const app = Fastify();
  app.get('/healthz', async () => ({ ok: true }));
  return app;
}
