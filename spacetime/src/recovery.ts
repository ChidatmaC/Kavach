// Mirror of shared/recovery_library.yaml (D10): which vetted step keys each shared
// item triggers, and each step's priority. Wording lives only in the YAML; the agent
// service words steps for people. agents/tests/test_recovery_consistency.py checks
// that this file and the YAML agree.

export const STEP_PRIORITY: Record<string, 'now' | 'today' | 'this_week'> = {
  call_bank_freeze_card: 'now',
  call_bank_stop_transfer: 'now',
  contact_carrier_account_lock: 'now',
  change_password_reused: 'now',
  enable_2fa: 'today',
  gift_card_issuer: 'now',
  keep_receipts: 'today',
  uninstall_remote_app: 'now',
  device_checkup: 'today',
  credit_freeze: 'today',
  watch_statements: 'this_week',
  password_change_link: 'today',
  report_ftc: 'this_week',
  report_ic3: 'this_week',
  tell_family: 'today',
};

export const ITEM_STEPS: Record<string, string[]> = {
  code: ['contact_carrier_account_lock', 'change_password_reused', 'enable_2fa'],
  pin: ['call_bank_freeze_card', 'change_password_reused'],
  password: ['change_password_reused', 'enable_2fa'],
  card: ['call_bank_freeze_card', 'watch_statements'],
  gift_card: ['gift_card_issuer', 'keep_receipts'],
  money: ['call_bank_stop_transfer', 'keep_receipts', 'watch_statements'],
  remote_app: ['uninstall_remote_app', 'device_checkup', 'change_password_reused'],
  personal_details: ['credit_freeze', 'watch_statements'],
  link: ['password_change_link', 'watch_statements'],
};

export const CRITICAL_ALWAYS = ['tell_family', 'report_ftc'];

const PRIORITY_RANK = { now: 0, today: 1, this_week: 2 } as const;

/** Ordered, de-duplicated step keys for a set of shared items. */
export function recoveryStepsFor(
  sharedItems: string[],
  critical: boolean
): Array<{ key: string; priority: 'now' | 'today' | 'this_week' }> {
  const keys: string[] = [];
  for (const item of sharedItems) {
    for (const k of ITEM_STEPS[item] ?? []) if (!keys.includes(k)) keys.push(k);
  }
  if (critical) for (const k of CRITICAL_ALWAYS) if (!keys.includes(k)) keys.push(k);
  return keys
    .map((key, i) => ({ key, priority: STEP_PRIORITY[key], i }))
    .sort((a, b) => PRIORITY_RANK[a.priority] - PRIORITY_RANK[b.priority] || a.i - b.i)
    .map(({ key, priority }) => ({ key, priority }));
}
