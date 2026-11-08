import { setLogSink } from '../src/log';

// Quiet by default; DEBUG_LOGS=1 npm test to see the worker's JSON logs.
if (!process.env.DEBUG_LOGS) setLogSink(() => undefined);
