/**
 * Typed wrapper around the backend keychain Tauri commands.
 *
 * The backend stores credentials in the macOS Keychain (on macOS) or no-ops
 * with a clear error on other platforms. Call {@link keychainAvailable} once
 * at UI mount to gate "Save to Keychain" controls; it hides the feature
 * gracefully on unsupported platforms.
 */

import { invoke } from '@tauri-apps/api/core';

export type CredentialKind =
  | 'ssh_password'
  | 'ssh_key_passphrase'
  | 'sftp_password'
  | 'sftp_key_passphrase'
  | 'ftp_password';

/**
 * Whether the backend can actually read/write the OS keychain on this build.
 * Returns false for any invoke failure so the UI falls back to a plain
 * password prompt even if the command isn't registered for some reason.
 */
export async function keychainAvailable(): Promise<boolean> {
  try {
    return await invoke<boolean>('keychain_available');
  } catch {
    return false;
  }
}

export async function keychainSave(
  kind: CredentialKind,
  account: string,
  secret: string,
): Promise<void> {
  await invoke('keychain_save', { kind, account, secret });
}

export async function keychainLoad(
  kind: CredentialKind,
  account: string,
): Promise<string | null> {
  const result = await invoke<string | null>('keychain_load', {
    kind,
    account,
  });
  return result ?? null;
}

export async function keychainDelete(
  kind: CredentialKind,
  account: string,
): Promise<void> {
  await invoke('keychain_delete', { kind, account });
}

/**
 * Stable Keychain account identifier for a (host, port, username) tuple.
 * Using this consistently means the same credential is reused across
 * reconnects to the same endpoint, and distinct endpoints never collide.
 */
export function accountFor(
  host: string,
  port: number,
  username: string,
): string {
  return `${username}@${host}:${port}`;
}

/**
 * Map a (protocol, authMethod) pair to the CredentialKind that identifies
 * its stored secret, or null if this combination has no secret to store
 * (e.g. anonymous FTP, or public-key auth without a passphrase).
 */
export function credentialKindFor(
  protocol: string,
  authMethod: string,
): CredentialKind | null {
  const p = protocol.toUpperCase();
  if (p === 'SSH') {
    if (authMethod === 'password') return 'ssh_password';
    if (authMethod === 'publickey') return 'ssh_key_passphrase';
  } else if (p === 'SFTP') {
    if (authMethod === 'password') return 'sftp_password';
    if (authMethod === 'publickey') return 'sftp_key_passphrase';
  } else if (p === 'FTP') {
    if (authMethod === 'password') return 'ftp_password';
  }
  return null;
}
