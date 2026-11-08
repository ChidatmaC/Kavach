// Client for the agent service (docs/CONTRACTS.md section 4). 20 s budget per call (spec 13).
export type Intent =
  | 'scam_check' | 'advise' | 'command' | 'verify_relative' | 'interview' | 'pause' | 'resume' | 'stop' | 'help'
  | 'out_of_scope' | 'clarify';

export interface RouterResult {
  intent: Intent | string;
  args?: Record<string, unknown>;
}

export interface ScamCheckResult {
  verdict: string;
  reason: string;
  campaign_id?: number;
  tips?: string[];
  evidence_count?: number;
}

export interface AdviseResult {
  verdict: 'safe' | 'suspicious' | 'likely_scam';
  answer: string;
  next_steps: string[];
  evidence_count: number;
  already_shared: boolean;
}

export interface InterviewResult {
  next_question?: string;
  question_id?: string;
  say?: string;
  done: boolean;
  severity?: string;
}

export interface VerifyRelativeResult {
  verification_id: number;
  messages?: string[];
}

export class AgentError extends Error {}

export class AgentClient {
  constructor(private readonly baseUrl: string, private readonly token: string, private readonly timeoutMs = 20_000) {}

  private async post<T>(path: string, body: Record<string, unknown>): Promise<T> {
    let res: Response;
    try {
      res = await fetch(`${this.baseUrl}${path}`, {
        method: 'POST',
        headers: { authorization: `Bearer ${this.token}`, 'content-type': 'application/json' },
        body: JSON.stringify(body),
        signal: AbortSignal.timeout(this.timeoutMs),
      });
    } catch (err) {
      throw new AgentError(`${path}: ${(err as Error).name === 'TimeoutError' ? 'timeout' : (err as Error).message}`);
    }
    if (!res.ok) throw new AgentError(`${path}: HTTP ${res.status}`);
    return (await res.json()) as T;
  }

  router(a: { text: string; from_e164: string; channel: string; person_id: number }): Promise<RouterResult> {
    return this.post('/run/router', { ...a, mode: 'text' });
  }

  scamCheck(a: {
    person_id: number; text: string; sender_e164?: string; source: string;
    reply_to_e164?: string; reply_channel?: string; image_base64?: string; teach_wrapper?: boolean;
  }): Promise<ScamCheckResult> {
    return this.post('/run/scam_check', a);
  }

  advise(a: { person_id: number; text: string; reply_to_e164?: string; reply_channel?: string }): Promise<AdviseResult> {
    return this.post('/run/advise', { ...a, mode: 'text' });
  }

  /** iMessage commands understood by the model (report, family list, status, code word...). Queues its own reply. */
  command(a: {
    person_id: number; text: string; reply_to_e164?: string; reply_channel?: string; args?: Record<string, unknown>;
  }): Promise<Record<string, unknown>> {
    return this.post('/run/command', a);
  }

  verifyRelative(a: { person_id: number; relative_name: string; claim_from_e164?: string }): Promise<VerifyRelativeResult> {
    return this.post('/run/verify_relative', a);
  }

  interview(a: { incident_id: number; mode: 'text'; utterance?: string }): Promise<InterviewResult> {
    return this.post('/run/interview', a);
  }

  push(a: { to_e164: string; title: string; body: string; category: string; verification_id?: number }): Promise<{ sent: boolean }> {
    return this.post('/push', a);
  }
}
