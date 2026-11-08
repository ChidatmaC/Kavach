// GET /health -> {"ok": true, ...}. ok turns false when the outbox poll has stalled.
import { createServer, type Server } from 'node:http';
import type { OutboxStats } from './outbox';

export function startHealthServer(
  port: number,
  info: () => { gateway: string; outbox: OutboxStats; pollMs: number }
): Promise<Server> {
  const server = createServer((req, res) => {
    if (req.method === 'GET' && (req.url === '/health' || req.url === '/')) {
      const i = info();
      const stalledMs = i.outbox.lastPollAt ? Date.now() - i.outbox.lastPollAt : null;
      const ok = stalledMs !== null && stalledMs < Math.max(10_000, i.pollMs * 20);
      res.writeHead(ok ? 200 : 503, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ ok, gateway: i.gateway, last_poll_ms_ago: stalledMs, ...i.outbox }));
      return;
    }
    res.writeHead(404, { 'content-type': 'application/json' });
    res.end('{"error":"not found"}');
  });
  return new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(port, '127.0.0.1', () => resolve(server));
  });
}
