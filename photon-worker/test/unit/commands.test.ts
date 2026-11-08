import { describe, expect, it } from 'vitest';
import { normalize, parseCommand, sameName } from '../../src/commands';

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
