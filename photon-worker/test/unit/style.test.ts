import { describe, expect, it } from 'vitest';
import { parseConsoleLine } from '../../src/gateway/console';
import { styleBody } from '../../src/style';

describe('styleBody', () => {
  it('keeps official links and defangs others', () => {
    const out = styleBody('Likely scam. The link txtag-pay.top/inv/88213 is fake. Report it at https://ReportFraud.ftc.gov', 'reply');
    expect(out).toContain('txtag-pay[.]top/inv/88213');
    expect(out).toContain('https://ReportFraud.ftc.gov');
  });
  it('allows at most 2 links', () => {
    const out = styleBody('a ftc.gov b reportfraud.ftc.gov c identitytheft.gov', 'reply');
    expect(out).toBe('a ftc.gov b reportfraud.ftc.gov c identitytheft[.]gov');
  });
  it('allows extra app domains', () => {
    expect(styleBody('Open kavach.app/check', 'reply', ['kavach.app'])).toBe('Open kavach.app/check');
  });
  it('leaves money and plain text alone, caps length', () => {
    expect(styleBody('Pay $4.35 now? No.', 'reply')).toBe('Pay $4.35 now? No.');
    expect(styleBody('x'.repeat(700), 'reply')).toHaveLength(600);
    expect(styleBody('x'.repeat(1100), 'briefing')).toHaveLength(1100);
  });
});

describe('console input', () => {
  it('parses number, optional channel and text', () => {
    expect(parseConsoleLine('+15555550101> verify Tommy')).toMatchObject({ from: '+15555550101', channel: 'imessage', text: 'verify Tommy' });
    expect(parseConsoleLine('+15555550103:sms> stop')).toMatchObject({ from: '+15555550103', channel: 'sms', text: 'stop' });
    expect(parseConsoleLine('hello')).toBeNull();
  });
});
