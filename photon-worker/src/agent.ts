// Client for the agent service (docs/CONTRACTS.md section 4). 20 s budget per call (spec 13).
export type Intent =
  | 'scam_check' | 'verify_relative' | 'interview' | 'pause' | 'resume' | 'stop' | 'help' | 'out_of_scope';

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
    reply_to_e164?: string; reply_channel?: string; image_base64?: string;
  }): Promise<ScamCheckResult> {
    return this.post('/run/scam_check', a);
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
