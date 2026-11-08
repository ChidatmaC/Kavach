// Outbound message style (spec 9): short, at most 2 links, links only to the app or official
// sites, under 600 characters (briefings 1200). The module already caps length on insert;
// this is the last check before a message leaves, so a quoted scam link can never be tappable.

export const MAX_BODY = 600;
export const MAX_BRIEFING_BODY = 1200;
export const MAX_LINKS = 2;

/** Official sites a reply may link to. Subdomains count (consumer.ftc.gov). */
export const OFFICIAL_DOMAINS = [
  'reportfraud.ftc.gov', 'ftc.gov', 'identitytheft.gov', 'consumer.gov', 'fcc.gov', 'ic3.gov', 'usa.gov',
  'aarp.org', 'donotcall.gov', 'annualcreditreport.com',
];

const URL_RE = /\b(?:https?:\/\/)?(?:[a-z0-9-]+\.)+[a-z]{2,24}(?:\/[^\s)]*)?/gi;

function hostOf(link: string): string {
  return link.replace(/^https?:\/\//i, '').split(/[/?#:]/)[0].toLowerCase().replace(/^www\./, '');
}

function allowed(host: string, extra: string[]): boolean {
  return [...OFFICIAL_DOMAINS, ...extra].some(d => host === d || host.endsWith(`.${d}`));
}

/** "txtag-pay.top/inv" -> "txtag-pay[.]top/inv": readable, not tappable. */
export function defang(link: string): string {
  return link.replace(/^https?:\/\//i, '').replace(/\./g, '[.]');
}

export function styleBody(body: string, kind: string, extraDomains: string[] = []): string {
  let kept = 0;
  let out = body.replace(URL_RE, match => {
    // Skip things that only look like domains inside words, e.g. "e.g" or decimals.
    const host = hostOf(match);
    if (!host.includes('.')) return match;
    if (allowed(host, extraDomains) && kept < MAX_LINKS) {
      kept++;
      return match;
    }
    return defang(match);
  });
  out = out.replace(/[ \t]+\n/g, '\n').trim();
  const limit = kind === 'briefing' ? MAX_BRIEFING_BODY : MAX_BODY;
  if (out.length > limit) out = `${out.slice(0, limit - 1).trimEnd()}…`;
  return out;
}
