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

export async function keychainList(kind: CredentialKind): Promise<string[]> {
  const result = await invoke<string[]>('keychain_list', { kind });
  return result ?? [];
}

/** User-friendly label for a CredentialKind, for UI lists. */
export function credentialKindLabel(kind: CredentialKind): string {
  switch (kind) {
    case 'ssh_password':
      return 'SSH password';
    case 'ssh_key_passphrase':
      return 'SSH key passphrase';
    case 'sftp_password':
      return 'SFTP password';
    case 'sftp_key_passphrase':
      return 'SFTP key passphrase';
    case 'ftp_password':
      return 'FTP password';
  }
}

/** All known credential kinds, in a UI-friendly order. */
export const ALL_CREDENTIAL_KINDS: readonly CredentialKind[] = [
  'ssh_password',
  'ssh_key_passphrase',
  'sftp_password',
  'sftp_key_passphrase',
  'ftp_password',
] as const;

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

export interface ResolvedSecrets {
  password: string | null;
  passphrase: string | null;
}

/**
 * Resolve the effective password + passphrase for a connection, preferring the
 * Keychain over the localStorage fallback. Callers should pass the stored
 * fallback values; this function only overrides a field when the Keychain has
 * an actual value for the relevant credential kind.
 *
 * Keychain lookup failures are logged and swallowed — the legacy localStorage
 * value is used so a broken Keychain can never block a reconnect.
 */
export async function resolveSecrets(
  protocol: string,
  authMethod: string,
  host: string,
  port: number,
  username: string,
  fallback: { password?: string | null; passphrase?: string | null } = {},
): Promise<ResolvedSecrets> {
  const password = fallback.password ?? null;
  const passphrase = fallback.passphrase ?? null;

  const kind = credentialKindFor(protocol, authMethod);
  if (!kind) return { password, passphrase };

  const account = accountFor(host, port, username);
  try {
    const fromKeychain = await keychainLoad(kind, account);
    if (!fromKeychain) return { password, passphrase };

    // The credential kind identifies which slot the secret belongs in.
    const isPassphrase =
      kind === 'ssh_key_passphrase' || kind === 'sftp_key_passphrase';
    return isPassphrase
      ? { password, passphrase: fromKeychain }
      : { password: fromKeychain, passphrase };
  } catch (err) {
    // Deliberately log-and-fallback so a Keychain access failure cannot
    // block a reconnect that would otherwise succeed with stored creds.
    console.error('Keychain lookup failed, falling back:', err);
    return { password, passphrase };
  }
}
