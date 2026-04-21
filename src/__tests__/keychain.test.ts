import { describe, it, expect } from 'vitest';
import {
  accountFor,
  credentialKindFor,
  parseAccount,
} from '../lib/keychain';

describe('accountFor', () => {
  it('produces a canonical user@host:port string', () => {
    expect(accountFor('example.com', 22, 'alice')).toBe('alice@example.com:22');
    expect(accountFor('10.0.0.1', 2222, 'root')).toBe('root@10.0.0.1:2222');
  });
});

describe('parseAccount', () => {
  it('round-trips with accountFor for a normal tuple', () => {
    const account = accountFor('example.com', 22, 'alice');
    expect(parseAccount(account)).toEqual({
      user: 'alice',
      host: 'example.com',
      port: '22',
    });
  });

  it('handles non-default ports', () => {
    expect(parseAccount('deploy@10.0.0.5:2222')).toEqual({
      user: 'deploy',
      host: '10.0.0.5',
      port: '2222',
    });
  });

  it('allows @ in usernames by taking the last @', () => {
    expect(parseAccount('alice@example@host:22')).toEqual({
      user: 'alice@example',
      host: 'host',
      port: '22',
    });
  });

  it('falls back to host-only when the port is missing', () => {
    expect(parseAccount('alice@example.com')).toEqual({
      user: 'alice',
      host: 'example.com',
    });
  });

  it('falls back to raw host string when the port is not purely numeric', () => {
    // Non-numeric port, e.g. "[::1]:ssh" — keep the user but leave the
    // right-hand side unparsed, so the UI shows the full string rather
    // than hiding it.
    expect(parseAccount('alice@host:ssh')).toEqual({
      user: 'alice',
      host: 'host:ssh',
    });
  });

  it('returns {} for strings without a user part', () => {
    expect(parseAccount('no-at-sign')).toEqual({});
    expect(parseAccount('@nothing-before')).toEqual({});
    expect(parseAccount('nothing-after@')).toEqual({});
  });
});

describe('credentialKindFor', () => {
  it('maps each known protocol+auth pair', () => {
    expect(credentialKindFor('SSH', 'password')).toBe('ssh_password');
    expect(credentialKindFor('SSH', 'publickey')).toBe('ssh_key_passphrase');
    expect(credentialKindFor('SFTP', 'password')).toBe('sftp_password');
    expect(credentialKindFor('SFTP', 'publickey')).toBe('sftp_key_passphrase');
    expect(credentialKindFor('FTP', 'password')).toBe('ftp_password');
  });

  it('is case-insensitive on the protocol', () => {
    expect(credentialKindFor('ssh', 'password')).toBe('ssh_password');
    expect(credentialKindFor('Sftp', 'publickey')).toBe('sftp_key_passphrase');
  });

  it('returns null for combos with no secret to store', () => {
    // Anonymous FTP: no secret.
    expect(credentialKindFor('FTP', 'anonymous')).toBeNull();
    // Unknown protocol.
    expect(credentialKindFor('Telnet', 'password')).toBeNull();
    // Unknown auth method.
    expect(credentialKindFor('SSH', 'keyboard-interactive')).toBeNull();
  });
});
