import { describe, expect, it } from 'vitest';
import { forwardWrapper, isClarifyAnswer, isShortAck, normalize, parseCommand, sameName } from '../../src/commands';

describe('parseCommand', () => {
  it.each([
    ['verify Tommy', { type: 'verify', name: 'Tommy' }],
    ['Verify tommy', { type: 'verify', name: 'Tommy' }],
    ['  VERIFY   mary ann ', { type: 'verify', name: 'Mary Ann' }],
    ['join Joe', { type: 'join', name: 'Joe' }],
    ['Join grandpa joe!', { type: 'join', name: 'Grandpa Joe' }],
  ])('%s', (text, expected) => {
    expect(parseCommand(text)).toEqual(expected);
  });

  it.each(['yes', 'Yes', 'YES!', "it's me", 'It’s me', 'its me', 'confirmed', 'Confirmed.', 'yes it\'s me'])(
    'confirm: %s', text => expect(parseCommand(text)).toEqual({ type: 'confirm' }));

  it.each(['no', 'No.', 'not me', 'Not me!', 'NO NOT ME', "it wasn't me", 'It wasn’t me', 'nope'])(
    'deny: %s', text => expect(parseCommand(text)).toEqual({ type: 'deny' }));

  it.each(["I'm calling", 'im calling', 'I’m calling!', 'I am calling', 'on it', 'On it.', 'calling now', "I'm calling him", "I'll call her now"])(
    'ack: %s', text => expect(parseCommand(text)).toEqual({ type: 'ack' }));

  it.each([
    ['pause', 'pause'], ['PAUSE', 'pause'], ['resume', 'resume'], ['stop', 'stop'], ['STOP', 'stop'],
    ['unsubscribe', 'stop'], ['start', 'start'], ['help', 'help'], ['Help?', 'help'],
  ])('%s -> %s', (text, type) => expect(parseCommand(text)).toEqual({ type }));

  it.each([
    'no way, is this a scam?',
    'Yes I got a text from my bank',
    'please stop calling me says the message',
    'verify',
    'Hey Grandpa it\'s me, I got a new number',
    'TxTag: You have an unpaid toll balance of $6.80',
    '',
    '   ',
  ])('not a command: %s', text => expect(parseCommand(text)).toBeNull());
});

describe('helpers', () => {
  it('normalizes case, spacing, curly quotes and trailing punctuation', () => {
    expect(normalize('  It’s   ME!! ')).toBe("it's me");
  });
  it('compares names loosely', () => {
    expect(sameName('Joe', ' joe ')).toBe(true);
    expect(sameName('Joe', 'Jo')).toBe(false);
  });
});

describe('isShortAck', () => {
  it.each(['ok', 'OK', 'Okay.', 'got it', 'Got it!', 'seen', 'thanks', 'Thank you!', '👍', '👍🏽', '❤️', 'will call', 'On my way'])(
    'short ack: %s', text => expect(isShortAck(text)).toBe(true));
  it.each(['ok is this a scam?', "Thanks, I'll check on Grandpa tonight", 'Driving over after work', '', 'no'])(
    'not a short ack: %s', text => expect(isShortAck(text)).toBe(false));
  it('short acks are not commands', () => expect(parseCommand('ok')).toBeNull());
});

describe('forward wrapper (CONTRACTS section 7)', () => {
  it.each([
    ['Forwarded message:\n"send money"', 'send money'],
    ['Forwarded message "send money"', 'send money'],
    ['forwarded: “Hi Grandpa it’s me”', 'Hi Grandpa it’s me'],
    ['Fwd: verify Tommy', 'verify Tommy'],
    ['FW: ok', 'ok'],
    ['Check this\n"stop"', 'stop'],
    ['Check this message: pay now', 'pay now'],
    ['Is this a scam? USPS: your package is on hold', 'USPS: your package is on hold'],
    ['Scam? ‘yes’', 'yes'],
    ['Forwarded message:\nFrom: +1 555 555 0144\n"Your toll is unpaid"', 'Your toll is unpaid'],
  ])('%j -> %j', (text, inner) => expect(forwardWrapper(text)).toEqual({ inner, bare: false }));

  it.each(['Fwd:', 'Forwarded message:', 'check this', 'Scam?', 'Is this a scam?'])(
    'bare marker: %s', text => expect(forwardWrapper(text)).toEqual({ inner: '', bare: true }));

  it.each(['Check this out', 'should I send money?', 'Forwarded it to my son', 'Is this a scam if he wants gift cards?', 'verify Tommy'])(
    'not wrapped: %s', text => expect(forwardWrapper(text)).toBeNull());

  it.each(['Forwarded message:\n"verify Tommy"', 'Fwd: verify Tommy', 'Check this: join Joe', 'Fwd: yes', 'Fwd: help', 'Check this "stop"'])(
    'a wrapped text is never a local command: %j', text => expect(parseCommand(text)).toBeNull());

  it('a quoted pasted text is not a verify/join command', () => {
    expect(parseCommand('"Verify your account"')).toBeNull();
    expect(parseCommand('“join us today”')).toBeNull();
    expect(parseCommand('verify Tommy')).toEqual({ type: 'verify', name: 'Tommy' });
  });

  it('wrapped acknowledgements are not short acks for the family path', () => {
    // inbound.ts checks forwardWrapper before isShortAck; the wrapper itself is never a short ack.
    expect(isShortAck('Fwd: ok')).toBe(false);
    expect(forwardWrapper('Fwd: ok')).toEqual({ inner: 'ok', bare: false });
  });

  it.each(['1', '2', '1.', 'received', 'question', 'Mine', "it's my question", 'It’s mine'])(
    'clarify answer: %s', text => expect(isClarifyAnswer(text)).toBe(true));
  it.each(['12', 'ok', 'yes', 'send money'])('not a clarify answer: %s', text => expect(isClarifyAnswer(text)).toBe(false));
});
