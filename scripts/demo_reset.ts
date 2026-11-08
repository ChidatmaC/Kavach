// Restores the seeded demo state in one command: wipe app data, then re-seed.
import { call, tokenFor } from './lib/stdb';
import { runSeed } from './seed';

await call(tokenFor('admin'), 'admin_reset', {});
await runSeed();
console.log('Demo state restored.');
