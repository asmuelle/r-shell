import { useCallback, useEffect, useState } from 'react';
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from './ui/card';
import { Button } from './ui/button';
import { KeyRound, Trash2, Loader2 } from 'lucide-react';
import { toast } from 'sonner';
import {
  ALL_CREDENTIAL_KINDS,
  credentialKindLabel,
  keychainAvailable,
  keychainDelete,
  keychainList,
  type CredentialKind,
} from '../lib/keychain';

interface Entry {
  kind: CredentialKind;
  account: string;
}

/**
 * "Saved Credentials" section for the Settings modal.
 *
 * Loads every account across every known credential kind from the system
 * Keychain and lets the user remove individual entries. Hides itself with a
 * short explanation on platforms without a keychain (e.g. Linux / Windows
 * today, where the backend module returns empty lists rather than erroring).
 */
export function KeychainCredentialsCard() {
  const [supported, setSupported] = useState<boolean | null>(null);
  const [entries, setEntries] = useState<Entry[]>([]);
  const [loading, setLoading] = useState(true);
  const [deletingKey, setDeletingKey] = useState<string | null>(null);

  const reload = useCallback(async () => {
    setLoading(true);
    try {
      // Fire the list calls concurrently — they touch independent Keychain
      // services and don't depend on each other.
      const buckets = await Promise.all(
        ALL_CREDENTIAL_KINDS.map(async kind => {
          const accounts = await keychainList(kind);
          return accounts.map<Entry>(account => ({ kind, account }));
        }),
      );
      const flat = buckets.flat();
      flat.sort((a, b) => {
        // Primary sort by kind order so UI stays stable across reloads.
        const kindOrder =
          ALL_CREDENTIAL_KINDS.indexOf(a.kind)
          - ALL_CREDENTIAL_KINDS.indexOf(b.kind);
        if (kindOrder !== 0) return kindOrder;
        return a.account.localeCompare(b.account);
      });
      setEntries(flat);
    } catch (err) {
      console.error('Failed to list keychain entries:', err);
      toast.error('Failed to load Keychain entries', {
        description: err instanceof Error ? err.message : String(err),
      });
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    let cancelled = false;
    keychainAvailable()
      .then(available => {
        if (cancelled) return;
        setSupported(available);
        if (available) return reload();
        setLoading(false);
      })
      .catch(() => {
        if (cancelled) return;
        setSupported(false);
        setLoading(false);
      });
    return () => {
      cancelled = true;
    };
  }, [reload]);

  const handleDelete = async (entry: Entry) => {
    const key = `${entry.kind}:${entry.account}`;
    setDeletingKey(key);
    try {
      await keychainDelete(entry.kind, entry.account);
      toast.success('Credential removed');
      setEntries(prev =>
        prev.filter(
          e => !(e.kind === entry.kind && e.account === entry.account),
        ),
      );
    } catch (err) {
      console.error('Failed to delete keychain entry:', err);
      toast.error('Could not remove credential', {
        description: err instanceof Error ? err.message : String(err),
      });
    } finally {
      setDeletingKey(null);
    }
  };

  // Platform doesn't support a keychain — render a short static explanation
  // instead of a permanently-empty list.
  if (supported === false) {
    return (
      <Card>
        <CardHeader>
          <CardTitle className="flex items-center gap-2">
            <KeyRound className="h-4 w-4" />
            Saved Credentials
          </CardTitle>
          <CardDescription>
            Keychain storage is only available on macOS. On this platform,
            passwords remain stored in the app's local settings.
          </CardDescription>
        </CardHeader>
      </Card>
    );
  }

  return (
    <Card>
      <CardHeader>
        <CardTitle className="flex items-center gap-2">
          <KeyRound className="h-4 w-4" />
          Saved Credentials
        </CardTitle>
        <CardDescription>
          Passwords and key passphrases you have saved to the macOS Keychain.
          Removing an entry here forces the next connect to prompt again.
        </CardDescription>
      </CardHeader>
      <CardContent>
        {loading || supported === null ? (
          <div className="flex items-center gap-2 text-sm text-muted-foreground py-2">
            <Loader2 className="h-4 w-4 animate-spin" />
            Loading entries…
          </div>
        ) : entries.length === 0 ? (
          <p className="text-sm text-muted-foreground py-2">
            No credentials saved yet. When you connect with "Save to Keychain"
            enabled, the password appears here.
          </p>
        ) : (
          <ul className="divide-y">
            {entries.map(entry => {
              const key = `${entry.kind}:${entry.account}`;
              const deleting = deletingKey === key;
              return (
                <li
                  key={key}
                  className="flex items-center justify-between py-2 gap-3"
                >
                  <div className="min-w-0 flex-1">
                    <div className="text-sm font-medium truncate">
                      {entry.account}
                    </div>
                    <div className="text-xs text-muted-foreground">
                      {credentialKindLabel(entry.kind)}
                    </div>
                  </div>
                  <Button
                    variant="ghost"
                    size="sm"
                    onClick={() => handleDelete(entry)}
                    disabled={deleting}
                  >
                    {deleting ? (
                      <Loader2 className="h-3.5 w-3.5 animate-spin" />
                    ) : (
                      <Trash2 className="h-3.5 w-3.5" />
                    )}
                    <span className="ml-1">
                      {deleting ? 'Removing…' : 'Remove'}
                    </span>
                  </Button>
                </li>
              );
            })}
          </ul>
        )}
      </CardContent>
    </Card>
  );
}
