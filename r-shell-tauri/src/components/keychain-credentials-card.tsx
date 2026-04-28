import { useCallback, useEffect, useMemo, useState } from 'react';
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from './ui/card';
import { Button } from './ui/button';
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from './ui/alert-dialog';
import { KeyRound, Trash2, Loader2 } from 'lucide-react';
import { toast } from 'sonner';
import {
  ALL_CREDENTIAL_KINDS,
  credentialKindLabel,
  keychainAvailable,
  keychainDelete,
  keychainList,
  parseAccount,
  type CredentialKind,
  type ParsedAccount,
} from '../lib/keychain';

interface Entry {
  kind: CredentialKind;
  account: string;
  /** Parsed view of `account` for display. All fields are optional because
   *  account strings are free-form at the backend — we never want parsing to
   *  make a credential invisible. */
  display: ParsedAccount;
}

/**
 * "Saved Credentials" section for the Settings modal.
 *
 * Groups entries by kind and renders each as a readable row (user @ host:port
 * when parseable). Offers individual and bulk delete per kind. Hides itself
 * with a short explanation on platforms without a keychain.
 */
export function KeychainCredentialsCard() {
  const [supported, setSupported] = useState<boolean | null>(null);
  const [entries, setEntries] = useState<Entry[]>([]);
  const [loading, setLoading] = useState(true);
  const [deletingKey, setDeletingKey] = useState<string | null>(null);
  const [bulkTarget, setBulkTarget] = useState<CredentialKind | null>(null);
  const [bulkRunning, setBulkRunning] = useState(false);

  const reload = useCallback(async () => {
    setLoading(true);
    try {
      const buckets = await Promise.all(
        ALL_CREDENTIAL_KINDS.map(async kind => {
          const accounts = await keychainList(kind);
          return accounts.map<Entry>(account => ({
            kind,
            account,
            display: parseAccount(account),
          }));
        }),
      );
      const flat = buckets.flat();
      flat.sort((a, b) => {
        const kindOrder =
          ALL_CREDENTIAL_KINDS.indexOf(a.kind)
          - ALL_CREDENTIAL_KINDS.indexOf(b.kind);
        if (kindOrder !== 0) return kindOrder;
        const aHost = a.display.host ?? a.account;
        const bHost = b.display.host ?? b.account;
        return aHost.localeCompare(bHost);
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

  /** Entries grouped by kind, preserving the existing sort. Kinds with no
   *  entries are omitted to keep the card tight. */
  const groups = useMemo(() => {
    const byKind = new Map<CredentialKind, Entry[]>();
    for (const entry of entries) {
      const list = byKind.get(entry.kind) ?? [];
      list.push(entry);
      byKind.set(entry.kind, list);
    }
    return ALL_CREDENTIAL_KINDS
      .filter(kind => byKind.has(kind))
      .map(kind => ({ kind, entries: byKind.get(kind)! }));
  }, [entries]);

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

  const handleBulkRemove = async () => {
    if (!bulkTarget) return;
    const toRemove = entries.filter(e => e.kind === bulkTarget);
    setBulkRunning(true);
    let removed = 0;
    let failed = 0;
    for (const entry of toRemove) {
      try {
        await keychainDelete(entry.kind, entry.account);
        removed++;
      } catch (err) {
        console.error('Bulk delete failed for', entry.account, err);
        failed++;
      }
    }
    setBulkRunning(false);
    setBulkTarget(null);
    // Re-sync from the OS so we show the truth, not an optimistic guess.
    await reload();
    if (failed === 0) {
      toast.success(`Removed ${removed} credential${removed === 1 ? '' : 's'}`);
    } else {
      toast.error(
        `Removed ${removed}, failed to remove ${failed}`,
      );
    }
  };

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
    <>
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
            <div className="space-y-4">
              {groups.map(group => (
                <div key={group.kind} className="space-y-1">
                  <div className="flex items-center justify-between">
                    <div className="text-xs font-medium uppercase text-muted-foreground tracking-wide">
                      {credentialKindLabel(group.kind)}{' '}
                      <span className="font-normal normal-case">
                        ({group.entries.length})
                      </span>
                    </div>
                    {group.entries.length > 1 && (
                      <Button
                        variant="ghost"
                        size="sm"
                        onClick={() => setBulkTarget(group.kind)}
                      >
                        <Trash2 className="h-3.5 w-3.5 mr-1" />
                        Remove all
                      </Button>
                    )}
                  </div>
                  <ul className="divide-y border rounded-md">
                    {group.entries.map(entry => {
                      const rowKey = `${entry.kind}:${entry.account}`;
                      const deleting = deletingKey === rowKey;
                      const { user, host, port } = entry.display;
                      return (
                        <li
                          key={rowKey}
                          className="flex items-center justify-between px-3 py-2 gap-3"
                        >
                          <div className="min-w-0 flex-1">
                            {host ? (
                              <>
                                <div className="text-sm truncate">
                                  <span className="font-medium">{host}</span>
                                  {port && (
                                    <span className="text-muted-foreground">
                                      :{port}
                                    </span>
                                  )}
                                </div>
                                {user && (
                                  <div className="text-xs text-muted-foreground truncate">
                                    {user}
                                  </div>
                                )}
                              </>
                            ) : (
                              // Fallback for legacy / non-standard account strings.
                              <div className="text-sm truncate font-medium">
                                {entry.account}
                              </div>
                            )}
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
                </div>
              ))}
            </div>
          )}
        </CardContent>
      </Card>

      <AlertDialog
        open={bulkTarget !== null}
        onOpenChange={open => {
          if (!open && !bulkRunning) setBulkTarget(null);
        }}
      >
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>
              Remove all {bulkTarget ? credentialKindLabel(bulkTarget) : ''}{' '}
              credentials?
            </AlertDialogTitle>
            <AlertDialogDescription>
              {bulkTarget && (
                <>
                  This will delete{' '}
                  <span className="font-medium">
                    {entries.filter(e => e.kind === bulkTarget).length}
                  </span>{' '}
                  Keychain entr{entries.filter(e => e.kind === bulkTarget).length === 1 ? 'y' : 'ies'}.
                  You will be prompted to re-enter the password on the next connect.
                </>
              )}
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel disabled={bulkRunning}>Cancel</AlertDialogCancel>
            <AlertDialogAction
              onClick={e => {
                // Stop the default close-on-click; we close manually after the
                // async delete loop completes.
                e.preventDefault();
                void handleBulkRemove();
              }}
              disabled={bulkRunning}
            >
              {bulkRunning ? (
                <>
                  <Loader2 className="h-3.5 w-3.5 mr-1 animate-spin" />
                  Removing…
                </>
              ) : (
                'Remove all'
              )}
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </>
  );
}
