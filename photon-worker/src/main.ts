// photon-worker entry point: inbound texts -> SpacetimeDB/agents; outbox -> Photon (spec 9).
import { AgentClient } from './agent';
import { loadConfig } from './config';
import { createGateway } from './gateway/index';
import { startHealthServer } from './health';
import { InboundProcessor } from './inbound';
import { log } from './log';
import { OutboxProcessor } from './outbox';
import { Stdb } from './stdb';

const cfg = loadConfig();
const db = new Stdb(cfg.spacetimeUri, cfg.spacetimeDb, cfg.spacetimeToken);
const agent = new AgentClient(cfg.agentUrl, cfg.agentToken, cfg.agentTimeoutMs);
const gateway = await createGateway(cfg);
const inbound = new InboundProcessor(db, agent, { appName: cfg.appName, familyReplyWindowMs: cfg.familyReplyWindowMs });
const outbox = new OutboxProcessor(db, gateway, agent, {
  appName: cfg.appName, allowedLinkDomains: cfg.allowedLinkDomains, pollMs: cfg.pollMs,
});

await outbox.recoverInterrupted().catch(err => log.error('outbox.recover_failed', { err }));
await gateway.start(async ev => {
  try {
    await inbound.handle(ev);
  } catch {
    // already logged by InboundProcessor; keep receiving
  }
});
outbox.start();
const health = await startHealthServer(cfg.healthPort, () => ({ gateway: gateway.name, outbox: outbox.stats, pollMs: cfg.pollMs }));
log.info('worker.started', {
  gateway: gateway.name, db: cfg.spacetimeDb, agent_url: cfg.agentUrl, health_port: cfg.healthPort, poll_ms: cfg.pollMs,
});

let stopping = false;
async function shutdown(signal: string) {
  if (stopping) return;
  stopping = true;
  log.info('worker.stopping', { signal });
  outbox.stop();
  health.close();
  await gateway.stop().catch(() => undefined);
  process.exit(0);
}
process.on('SIGINT', () => void shutdown('SIGINT'));
process.on('SIGTERM', () => void shutdown('SIGTERM'));
