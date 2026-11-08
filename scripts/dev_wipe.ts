// Full wipe + reseed, including app-bound persons, so a phone number (e.g. Joe's) can be
// registered again from the app. demo_reset keeps app bindings; this does not.
import { call, tokenFor } from './lib/stdb';
import { runSeed } from './seed';

await call(tokenFor('admin'), 'admin_reset', {});
await call(tokenFor('admin'), 'admin_wipe', {});
await runSeed();
console.log('Wiped (including app sign-ups) and re-seeded.');
