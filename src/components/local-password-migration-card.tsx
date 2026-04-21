import { useCallback, useEffect, useState } from 'react';
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from './ui/card';
import { Button } from './ui/button';
import { UploadCloud, Loader2, CheckCircle2 } from 'lucide-react';
import { toast } from 'sonner';
import { ConnectionStorageManager, type ConnectionData } from '../lib/connection-storage';
import {
  accountFor,
  credentialKindFor,
  keychainAvailable,
  keychainLoad,
  keychainSave,
  type CredentialKind,
} from '../lib/keychain';

interface Candidate {
  connection: ConnectionData;
  kind: CredentialKind;
  account: string;
  secret: string;
  authMethod: 'password' | 'publickey';
}

function defaultPort(protocol: string): number {
  switch (protocol) {
    case 'FTP':
      return 21;
    case 'RDP':
      return 3389;
    case 'VNC':
      return 5900;
    default:
      return 22;
  }
}

/**
 * Scan stored connections for plaintext passwords/passphrases and return the
 * ones that can be moved into the Keychain.
 *
 * We deliberately do NOT probe the Keychain here — that would be N IPC round
 * trips on every Settings open. The migration itself is the right place to
 * check per-entry whether the Keychain already has a (possibly different)
 * value for that account.
 */
function scanCandidates(): Candidate[] {
  const connections = ConnectionStorageManager.getConnections();
  const out: Candidate[] = [];
  for (const c of connections) {
    const authMethod = c.authMethod;
    if (authMethod !== 'password' && authMethod !== 'publickey') continue;
    const kind = credentialKindFor(c.protocol, authMethod);
    if (!kind) continue;
    const secret = authMethod === 'password' ? c.password : c.passphrase;
    if (!secret) continue;
    if (!c.host || !c.username) continue;
    out.push({
      connection: c,
      kind,
      account: accountFor(c.host, c.port || defaultPort(c.protocol), c.username),
      secret,
      authMethod,
    });
  }
  return out;
}

interface MigrationSummary {
  moved: number;
  skipped: number;
  failed: number;
}

/**
 * Bulk-migrate any connections whose password/passphrase is still in local
 * storage into the macOS Keychain. Appears in Settings > Security, hides
 * itself when there is nothing to migrate or the platform has no keychain.
 */
export function LocalPasswordMigrationCard() {
  const [supported, setSupported] = useState<boolean | null>(null);
  const [candidates, setCandidates] = useState<Candidate[]>([]);
  const [running, setRunning] = useState(false);
  const [progress, setProgress] = useState<{ done: number; total: number } | null>(null);
  const [lastSummary, setLastSummary] = useState<MigrationSummary | null>(null);

  const rescan = useCallback(() => {
    setCandidates(scanCandidates());
  }, []);

  useEffect(() => {
    let cancelled = false;
    keychainAvailable()
      .then(available => {
        if (cancelled) return;
        setSupported(available);
        if (available) rescan();
      })
      .catch(() => {
        if (!cancelled) setSupported(false);
      });
    return () => {
      cancelled = true;
    };
  }, [rescan]);

  const runMigration = async () => {
    const toMigrate = [...candidates];
    setRunning(true);
    setLastSummary(null);
    setProgress({ done: 0, total: toMigrate.length });

    let moved = 0;
    let skipped = 0;
    let failed = 0;

    for (let i = 0; i < toMigrate.length; i++) {
      const c = toMigrate[i];
      setProgress({ done: i, total: toMigrate.length });
      try {
        // Conflict check: if the Keychain already has a different value for
        // this account, we keep the Keychain value and simply clear the local
        // copy. Matching or missing values fall through to an unconditional
        // save, which upserts.
        const existing = await keychainLoad(c.kind, c.account);
        if (existing && existing !== c.secret) {
          ConnectionStorageManager.updateConnection(c.connection.id, {
            ...(c.authMethod === 'password'
              ? { password: undefined }
              : { passphrase: undefined }),
          });
          skipped++;
          continue;
        }

        await keychainSave(c.kind, c.account, c.secret);
        ConnectionStorageManager.updateConnection(c.connection.id, {
          ...(c.authMethod === 'password'
            ? { password: undefined }
            : { passphrase: undefined }),
        });
        moved++;
      } catch (err) {
        console.error('Migration failed for', c.account, err);
        failed++;
      }
    }

    setProgress({ done: toMigrate.length, total: toMigrate.length });
    setRunning(false);
    const summary = { moved, skipped, failed };
    setLastSummary(summary);
    rescan();

    if (failed === 0 && moved + skipped > 0) {
      toast.success(
        `Migrated ${moved} credential${moved === 1 ? '' : 's'}` +
          (skipped > 0 ? `, skipped ${skipped} (already in Keychain)` : ''),
      );
    } else if (failed > 0) {
      toast.error(
        `Migration finished with ${failed} failure${failed === 1 ? '' : 's'}` +
          ` (${moved} moved, ${skipped} skipped)`,
      );
    }
  };

  // Don't render on platforms without a keychain — the migration card would
  // be an impossible offer on those.
  if (supported !== true) return null;

  // Hide once everything has been migrated to avoid clutter.
  if (candidates.length === 0 && !lastSummary) return null;

  return (
    <Card>
      <CardHeader>
        <CardTitle className="flex items-center gap-2">
          <UploadCloud className="h-4 w-4" />
          Migrate Local Passwords to Keychain
        </CardTitle>
        <CardDescription>
          Passwords and key passphrases that are still in local storage can be
          moved into the macOS Keychain in one step. Entries whose Keychain
          value already differs are kept as-is; the local copy is cleared either
          way, so the app settles on a single source of truth.
        </CardDescription>
      </CardHeader>
      <CardContent className="space-y-3">
        {candidates.length > 0 ? (
          <p className="text-sm">
            Found{' '}
            <span className="font-medium">{candidates.length}</span>{' '}
            connection{candidates.length === 1 ? '' : 's'} with credentials
            in local storage.
          </p>
        ) : (
          <p className="text-sm text-muted-foreground flex items-center gap-2">
            <CheckCircle2 className="h-4 w-4 text-emerald-500" />
            All stored credentials are now in the Keychain.
          </p>
        )}

        {running && progress && (
          <div className="text-sm text-muted-foreground flex items-center gap-2">
            <Loader2 className="h-4 w-4 animate-spin" />
            Migrating {progress.done} / {progress.total}…
          </div>
        )}

        {lastSummary && !running && (
          <div className="text-xs text-muted-foreground">
            Last run: {lastSummary.moved} moved
            {lastSummary.skipped > 0 && `, ${lastSummary.skipped} skipped`}
            {lastSummary.failed > 0 && `, ${lastSummary.failed} failed`}.
          </div>
        )}

        {candidates.length > 0 && (
          <div>
            <Button onClick={runMigration} disabled={running}>
              {running ? (
                <>
                  <Loader2 className="h-3.5 w-3.5 mr-1 animate-spin" />
                  Migrating…
                </>
              ) : (
                <>
                  <UploadCloud className="h-3.5 w-3.5 mr-1" />
                  Migrate {candidates.length} to Keychain
                </>
              )}
            </Button>
          </div>
        )}
      </CardContent>
    </Card>
  );
}
