import React, { useState, useEffect, useRef } from 'react';
import { invoke } from '@tauri-apps/api/core';
import { Dialog, DialogContent, DialogHeader, DialogTitle, DialogDescription, DialogFooter } from './ui/dialog';
import { Button } from './ui/button';
import { Input } from './ui/input';
import { Label } from './ui/label';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from './ui/select';
import { Tabs, TabsContent, TabsList, TabsTrigger } from './ui/tabs';

import { Switch } from './ui/switch';
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from './ui/card';

import { Separator } from './ui/separator';
import { ConnectionProfileManager, type ConnectionProfile } from '../lib/connection-profiles';
import { ConnectionStorageManager } from '../lib/connection-storage';
import {
  accountFor,
  credentialKindFor,
  keychainAvailable,
  keychainDelete,
  keychainLoad,
  keychainSave,
  type CredentialKind,
} from '../lib/keychain';
import { toast } from 'sonner';
import {
  Server,
  Shield,
  Key,
  Network,
  Terminal as TerminalIcon,
  Monitor,
  X as XIcon,
} from 'lucide-react';
import { getDefaultPort, getAuthMethods, getHiddenFields, isDesktopProtocol } from '@/lib/protocol-config';

interface ConnectionDialogProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onConnect: (config: ConnectionConfig) => void;
  editingConnection?: ConnectionConfig | null;
}

export interface ConnectionConfig {
  id?: string;
  name: string;
  protocol: 'SSH' | 'Telnet' | 'Raw' | 'Serial' | 'SFTP' | 'FTP' | 'RDP' | 'VNC';
  host: string;
  port: number;
  username: string;
  authMethod: 'password' | 'publickey' | 'keyboard-interactive' | 'anonymous';
  password?: string;
  privateKeyPath?: string;
  passphrase?: string;

  // Advanced options
  proxyType?: 'none' | 'http' | 'socks4' | 'socks5';
  proxyHost?: string;
  proxyPort?: number;
  proxyUsername?: string;
  proxyPassword?: string;

  // FTP specific
  ftpsEnabled?: boolean;

  // SSH specific
  compression?: boolean;
  keepAlive?: boolean;
  keepAliveInterval?: number;
  serverAliveCountMax?: number;

  // RDP specific
  domain?: string;
  rdpResolution?: '1024x768' | '1280x720' | '1920x1080' | 'fit';

  // VNC specific
  vncColorDepth?: '24' | '16' | '8';
}

export function ConnectionDialog({
  open,
  onOpenChange,
  onConnect,
  editingConnection
}: ConnectionDialogProps) {
  const defaultConfig: ConnectionConfig = {
    name: '',
    protocol: 'SSH',
    host: '',
    port: 22,
    username: 'root',
    authMethod: 'publickey',
    password: '',
    privateKeyPath: '~/.ssh/id_rsa',
    passphrase: '',
    proxyType: 'none',
    proxyHost: '',
    proxyPort: 8080,
    proxyUsername: '',
    proxyPassword: '',
    compression: true,
    keepAlive: true,
    keepAliveInterval: 60,
    serverAliveCountMax: 3
  };

  const [config, setConfig] = useState<ConnectionConfig>(defaultConfig);

  const [isConnecting, setIsConnecting] = useState(false);
  const [isCancelling, setIsCancelling] = useState(false);
  const [_savedProfiles, setSavedProfiles] = useState<ConnectionProfile[]>([]);
  const [_showSaveProfile, setShowSaveProfile] = useState(false);
  const [saveAsConnection, setSaveAsConnection] = useState(true);
  const [connectionFolder, setConnectionFolder] = useState('All Connections');
  const [availableFolders, setAvailableFolders] = useState<string[]>([]);
  // Keychain integration state.
  // `keychainSupported === null` means we haven't resolved it yet; the UI
  // stays hidden until the backend reports a concrete answer.
  const [keychainSupported, setKeychainSupported] = useState<boolean | null>(null);
  const [saveToKeychain, setSaveToKeychain] = useState(false);
  const [loadedFromKeychain, setLoadedFromKeychain] = useState(false);
  // Which (protocol, authMethod, account) combinations we have already
  // attempted to auto-load. Prevents us from re-firing the keychain prompt
  // on every re-render once the user has typed a value into the form.
  const attemptedKeychainLoadsRef = useRef<Set<string>>(new Set());
  const connectionIdRef = useRef<string | null>(null);
  const cancelRequestedRef = useRef(false);

  // Resolve keychain availability once on mount. The result is cached for the
  // lifetime of the component; it can't change at runtime.
  useEffect(() => {
    let cancelled = false;
    keychainAvailable()
      .then(available => {
        if (!cancelled) setKeychainSupported(available);
      })
      .catch(() => {
        if (!cancelled) setKeychainSupported(false);
      });
    return () => {
      cancelled = true;
    };
  }, []);

  // Reset connection state and load saved profiles when dialog opens/closes
  useEffect(() => {
    if (open) {
      // Reset connection state when dialog opens
      resetConnectionState();

      // Drop the auto-load memo each time the dialog re-opens so a re-open
      // after entering/exiting an edit can still trigger a fresh lookup.
      attemptedKeychainLoadsRef.current.clear();
      setLoadedFromKeychain(false);
      setSaveToKeychain(false);

      setSavedProfiles(ConnectionProfileManager.getProfiles());

      // Load only valid folders from connection manager (excludes orphaned/deleted folders)
      const folders = ConnectionStorageManager.getValidFolders();
      const folderPaths = folders.map(f => f.path).sort();
      setAvailableFolders(folderPaths);

      // Load editing connection data into config when dialog opens
      if (editingConnection) {
        setConfig({
          ...defaultConfig,
          ...editingConnection
        });
        // When editing, don't show "save as connection" since it already exists
        setSaveAsConnection(false);
      } else {
        // Reset to defaults for new connection
        setConfig(defaultConfig);
        setSaveAsConnection(true);
      }
    } else {
      // Reset connection state when dialog closes
      resetConnectionState();
    }
  }, [open, editingConnection]);

  // Auto-load saved credentials from the Keychain when the host/port/username/
  // auth combination identifies a known account and the corresponding secret
  // field is empty. Populating a field the user has already typed into would
  // be surprising, so we only fill blanks.
  useEffect(() => {
    if (!open) return;
    if (keychainSupported !== true) return;
    if (!config.host || !config.username || !config.port) return;

    const kind = credentialKindFor(config.protocol, config.authMethod);
    if (!kind) return;

    const currentSecret =
      config.authMethod === 'password' ? config.password : config.passphrase;
    if (currentSecret) return;

    const account = accountFor(config.host, config.port, config.username);
    const memoKey = `${kind}:${account}`;
    if (attemptedKeychainLoadsRef.current.has(memoKey)) return;
    attemptedKeychainLoadsRef.current.add(memoKey);

    let cancelled = false;
    keychainLoad(kind, account)
      .then(secret => {
        if (cancelled || !secret) return;
        setConfig(prev => {
          // Re-check that the user hasn't typed into the field between the
          // invoke firing and the promise resolving.
          const pending =
            prev.authMethod === 'password' ? prev.password : prev.passphrase;
          if (pending) return prev;
          return prev.authMethod === 'password'
            ? { ...prev, password: secret }
            : { ...prev, passphrase: secret };
        });
        setLoadedFromKeychain(true);
        setSaveToKeychain(true);
      })
      .catch(err => {
        console.error('Keychain load failed:', err);
      });

    return () => {
      cancelled = true;
    };
  }, [
    open,
    keychainSupported,
    config.protocol,
    config.authMethod,
    config.host,
    config.port,
    config.username,
    config.password,
    config.passphrase,
  ]);

  const _handleSaveProfile = () => {
    try {
      const profile = ConnectionProfileManager.saveProfile({
        name: config.name,
        host: config.host,
        port: config.port,
        username: config.username,
        authMethod: config.authMethod === 'publickey' ? 'key' : 'password',
        password: config.password,
        privateKey: config.privateKeyPath,
      });
      setSavedProfiles(ConnectionProfileManager.getProfiles());
      toast.success(`Saved profile: ${profile.name}`);
      setShowSaveProfile(false);
    } catch (_error) {
      toast.error('Failed to save profile');
    }
  };

  const _handleLoadProfile = (profile: ConnectionProfile) => {
    setConfig({
      ...config,
      name: profile.name,
      host: profile.host,
      port: profile.port,
      username: profile.username,
      authMethod: profile.authMethod === 'key' ? 'publickey' : 'password',
      password: profile.password,
      privateKeyPath: profile.privateKey,
    });
    toast.success(`Loaded profile: ${profile.name}`);
  };

  const _handleDeleteProfile = (id: string) => {
    if (ConnectionProfileManager.deleteProfile(id)) {
      setSavedProfiles(ConnectionProfileManager.getProfiles());
      toast.success('Profile deleted');
    }
  };

  const _handleToggleFavorite = (id: string) => {
    const profile = ConnectionProfileManager.getProfile(id);
    if (profile) {
      ConnectionProfileManager.updateProfile(id, { favorite: !profile.favorite });
      setSavedProfiles(ConnectionProfileManager.getProfiles());
    }
  };

  const resetConnectionState = () => {
    setIsConnecting(false);
    setIsCancelling(false);
    connectionIdRef.current = null;
    cancelRequestedRef.current = false;
  };

  /** Credential kind for the currently-selected protocol/auth pair, if any. */
  const currentCredentialKind = (): CredentialKind | null =>
    credentialKindFor(config.protocol, config.authMethod);

  /** Delete any saved Keychain credential for the current account and clear
   *  the field it would have populated. */
  const handleForgetCredential = async () => {
    const kind = currentCredentialKind();
    if (!kind || !config.host || !config.username || !config.port) return;
    const account = accountFor(config.host, config.port, config.username);
    try {
      await keychainDelete(kind, account);
      toast.success('Forgot saved credential');
      // Clear the field that the Keychain had populated.
      setConfig(prev =>
        prev.authMethod === 'password'
          ? { ...prev, password: '' }
          : { ...prev, passphrase: '' },
      );
      setLoadedFromKeychain(false);
      setSaveToKeychain(false);
      attemptedKeychainLoadsRef.current.delete(`${kind}:${account}`);
    } catch (err) {
      console.error('Keychain delete failed:', err);
      toast.error('Could not remove saved credential', {
        description: err instanceof Error ? err.message : String(err),
      });
    }
  };

  /** After a successful connect, persist the secret to the Keychain if the
   *  user opted in. Swallows (but logs + toasts) failures — the actual SSH
   *  connect has already succeeded. */
  const persistToKeychainIfRequested = async () => {
    if (!keychainSupported || !saveToKeychain) return;
    const kind = currentCredentialKind();
    if (!kind) return;
    const secret =
      config.authMethod === 'password' ? config.password : config.passphrase;
    if (!secret) return;
    const account = accountFor(config.host, config.port, config.username);
    try {
      await keychainSave(kind, account, secret);
      toast.success('Credential saved to Keychain');
    } catch (err) {
      console.error('Keychain save failed:', err);
      toast.error('Could not save credential to Keychain', {
        description: err instanceof Error ? err.message : String(err),
      });
    }
  };

  const handleConnect = async () => {
    if (isConnecting) {
      return;
    }

    setIsConnecting(true);
    setIsCancelling(false);
    cancelRequestedRef.current = false;
    const connectionId = editingConnection?.id || `connection-${Date.now()}`;
    connectionIdRef.current = connectionId;

    // Basic validation — anonymous FTP doesn't require a username
    // VNC also doesn't require a username
    const requiresUsername = config.authMethod !== 'anonymous' && config.protocol !== 'VNC';
    if (!config.name || !config.host || (requiresUsername && !config.username)) {
      toast.error('Missing Required Fields', {
        description: requiresUsername
          ? 'Please fill in all required fields: Connection Name, Host, and Username.'
          : 'Please fill in all required fields: Connection Name and Host.',
      });
      resetConnectionState();
      return;
    }

    // Validate authentication method specific fields
    if (config.authMethod === 'password' && !config.password) {
      toast.error('Password Required', {
        description: 'Please enter a password for password authentication.',
      });
      resetConnectionState();
      return;
    }

    if (config.authMethod === 'publickey' && !config.privateKeyPath) {
      toast.error('Private Key Required', {
        description: 'Please select or enter the path to your SSH private key file.',
      });
      resetConnectionState();
      return;
    }

    // For SFTP/FTP/RDP/VNC protocols, delegate connection to App.tsx (via onConnect)
    // which calls the appropriate Tauri commands.
    const isSftpOrFtp = config.protocol === 'SFTP' || config.protocol === 'FTP';
    const isDesktop = config.protocol === 'RDP' || config.protocol === 'VNC';

    // When the user opts to save credentials to the Keychain, keep them out
    // of localStorage entirely — the two stores would otherwise drift.
    const usingKeychainForSecret =
      keychainSupported === true
      && saveToKeychain
      && currentCredentialKind() !== null;
    const storedPassword =
      usingKeychainForSecret && config.authMethod === 'password'
        ? undefined
        : config.password;
    const storedPassphrase =
      usingKeychainForSecret && config.authMethod === 'publickey'
        ? undefined
        : config.passphrase;

    if (isSftpOrFtp || isDesktop) {
      try {
        // Save credential to the Keychain before handing off to App.tsx. We
        // save optimistically (even though the SFTP/FTP/RDP/VNC connect
        // happens asynchronously in App.tsx) because `set_generic_password`
        // overwrites, so a subsequent successful attempt self-corrects.
        await persistToKeychainIfRequested();

        // Save connection if requested
        if (editingConnection?.id) {
          ConnectionStorageManager.updateConnection(editingConnection.id, {
            name: config.name,
            host: config.host,
            port: config.port || (config.protocol === 'FTP' ? 21 : config.protocol === 'RDP' ? 3389 : config.protocol === 'VNC' ? 5900 : 22),
            username: config.username,
            protocol: config.protocol,
            authMethod: config.authMethod,
            password: storedPassword,
            privateKeyPath: config.privateKeyPath,
            passphrase: storedPassphrase,
            ftpsEnabled: config.ftpsEnabled,
            domain: config.domain,
            rdpResolution: config.rdpResolution,
            vncColorDepth: config.vncColorDepth,
            lastConnected: new Date().toISOString(),
          });
        } else if (saveAsConnection) {
          ConnectionStorageManager.saveConnectionWithId(connectionId, {
            name: config.name,
            host: config.host,
            port: config.port || (config.protocol === 'FTP' ? 21 : config.protocol === 'RDP' ? 3389 : config.protocol === 'VNC' ? 5900 : 22),
            username: config.username,
            protocol: config.protocol,
            folder: connectionFolder,
            authMethod: config.authMethod,
            password: storedPassword,
            privateKeyPath: config.privateKeyPath,
            passphrase: storedPassphrase,
            ftpsEnabled: config.ftpsEnabled,
            domain: config.domain,
            rdpResolution: config.rdpResolution,
            vncColorDepth: config.vncColorDepth,
          });
        }

        // Delegate actual connection to App.tsx handler
        onConnect({ ...config, id: connectionId });
        onOpenChange(false);

        if (!editingConnection) {
          setConfig(defaultConfig);
        }
      } finally {
        resetConnectionState();
      }
      return;
    }

    // SSH / Telnet / Raw / Serial — connect via ssh_connect
    try {
      const result = await invoke<{ success: boolean; error?: string }>(
        'ssh_connect',
        {
          request: {
            connection_id: connectionId,
            host: config.host,
            port: config.port || 22,
            username: config.username,
            auth_method: config.authMethod || 'password',
            password: config.password || '',
            key_path: config.privateKeyPath || null,
            passphrase: config.passphrase || null,
          }
        }
      );

      if (result.success) {
        // Persist the credential to the Keychain now that we know the auth
        // worked. Any failure is non-fatal — the SSH connection is already up.
        await persistToKeychainIfRequested();

        // Save or update connection based on whether we're editing or creating new
        if (editingConnection?.id) {
          // Update existing connection with new connection details
          ConnectionStorageManager.updateConnection(editingConnection.id, {
            name: config.name,
            host: config.host,
            port: config.port || 22,
            username: config.username,
            protocol: config.protocol,
            authMethod: config.authMethod,
            password: storedPassword,
            privateKeyPath: config.privateKeyPath,
            passphrase: storedPassphrase,
            lastConnected: new Date().toISOString(),
          });
        } else if (saveAsConnection) {
          // Save new connection with the same ID used for the SSH connection
          // This ensures the tab ID matches the connection ID in storage
          ConnectionStorageManager.saveConnectionWithId(connectionId, {
            name: config.name,
            host: config.host,
            port: config.port || 22,
            username: config.username,
            protocol: config.protocol,
            folder: connectionFolder,
            authMethod: config.authMethod,
            password: storedPassword,
            privateKeyPath: config.privateKeyPath,
            passphrase: storedPassphrase,
          });
        }

        onConnect({
          ...config,
          id: connectionId
        });
        onOpenChange(false);

        // Reset form if creating new connection
        if (!editingConnection) {
          setConfig(defaultConfig);
        }
      } else {
        // Show error toast
        console.error('Connection failed:', result.error);
        if (cancelRequestedRef.current && result.error?.toLowerCase().includes('cancelled')) {
          toast.info('Connection cancelled');
        } else {
          toast.error('Connection Failed', {
            description: result.error || 'Unable to connect to the server. Please check your credentials and try again.',
            duration: 5000,
          });
        }
      }
    } catch (error) {
      console.error('Connection error:', error);
      if (cancelRequestedRef.current) {
        toast.info('Connection cancelled');
      } else {
        toast.error('Connection Error', {
          description: error instanceof Error ? error.message : 'An unexpected error occurred while connecting.',
          duration: 5000,
        });
      }
    } finally {
      resetConnectionState();
    }
  };

  const handleCancelConnectionAttempt = async () => {
    if (!isConnecting) {
      onOpenChange(false);
      return;
    }

    if (isCancelling) {
      return;
    }

    const connectionId = connectionIdRef.current;
    if (!connectionId) {
      resetConnectionState();
      return;
    }

    cancelRequestedRef.current = true;
    setIsCancelling(true);

    try {
      const response = await invoke<{ success: boolean; error?: string }>('ssh_cancel_connect', {
        connection_id: connectionId
      });
      if (response.success) {
        toast.info('Connection cancelled');
      }
      // Whether successful or not, we want to reset the state
      // The user clicked cancel, so we should stop the "connecting" state
    } catch (error) {
      console.error('Failed to cancel connection:', error);
      // Don't show error toast - user just wants to stop, we'll reset the state
    } finally {
      // Always reset the state when user requests cancel
      resetConnectionState();
    }
  };

  const updateConfig = (updates: Partial<ConnectionConfig>) => {
    setConfig(prev => ({ ...prev, ...updates }));
  };

  const handleOpenChange = (newOpen: boolean) => {
    // If trying to close while connecting, cancel first then close
    if (!newOpen && isConnecting) {
      // Cancel connection and then close
      handleCancelConnectionAttempt().then(() => {
        resetConnectionState();
        onOpenChange(false);
      });
      return;
    }
    onOpenChange(newOpen);
  };

  return (
    <Dialog open={open} onOpenChange={handleOpenChange}>
      <DialogContent className="top-[50%] left-[50%] -translate-x-1/2 -translate-y-1/2 w-[900px] h-[680px] max-w-[90vw] max-h-[90vh] flex flex-col p-0 gap-0">
        <DialogHeader className="px-6 pt-6 pb-4 border-b">
          <DialogTitle className="flex items-center gap-2">
            <div className="p-2 bg-primary/10 rounded-lg">
              <Server className="h-5 w-5 text-primary" />
            </div>
            <div>
              <div>{editingConnection ? 'Edit Connection' : 'New Connection'}</div>
              <DialogDescription className="mt-1">
                Configure connection settings and authentication options
              </DialogDescription>
            </div>
          </DialogTitle>
        </DialogHeader>

        <Tabs defaultValue="connection" className="flex-1 flex flex-col overflow-hidden">
          <TabsList className="w-full justify-start rounded-none border-b bg-transparent h-auto p-0 px-4 overflow-x-auto">
            <TabsTrigger
              value="connection"
              className="flex items-center gap-1 rounded-none border-b-2 border-transparent data-[state=active]:border-primary data-[state=active]:bg-transparent data-[state=active]:shadow-none px-2.5 py-2.5 text-sm whitespace-nowrap"
            >
              <Server className="h-3.5 w-3.5" />
              <span>Connection</span>
            </TabsTrigger>
            <TabsTrigger
              value="authentication"
              className="flex items-center gap-1 rounded-none border-b-2 border-transparent data-[state=active]:border-primary data-[state=active]:bg-transparent data-[state=active]:shadow-none px-2.5 py-2.5 text-sm whitespace-nowrap"
            >
              <Shield className="h-3.5 w-3.5" />
              <span>Auth</span>
            </TabsTrigger>
            <TabsTrigger
              value="proxy"
              className="flex items-center gap-1 rounded-none border-b-2 border-transparent data-[state=active]:border-primary data-[state=active]:bg-transparent data-[state=active]:shadow-none px-2.5 py-2.5 text-sm whitespace-nowrap"
            >
              <Network className="h-3.5 w-3.5" />
              <span>Proxy</span>
            </TabsTrigger>
            <TabsTrigger
              value="advanced"
              className="flex items-center gap-1 rounded-none border-b-2 border-transparent data-[state=active]:border-primary data-[state=active]:bg-transparent data-[state=active]:shadow-none px-2.5 py-2.5 text-sm whitespace-nowrap"
            >
              <TerminalIcon className="h-3.5 w-3.5" />
              <span>Advanced</span>
            </TabsTrigger>
          </TabsList>

          <TabsContent value="connection" className="flex-1 overflow-y-auto px-6 py-4 space-y-4 mt-0">
            <Card>
              <CardHeader>
                <CardTitle className="flex items-center gap-2">
                  <Server className="h-4 w-4" />
                  Basic Connection Settings
                </CardTitle>
                <CardDescription>
                  Configure the basic connection parameters for your connection.
                </CardDescription>
              </CardHeader>
              <CardContent className="space-y-4">
                <div className="grid grid-cols-2 gap-4">
                  <div className="space-y-2">
                    <Label htmlFor="connection-name">Connection Name</Label>
                    <Input
                      id="connection-name"
                      placeholder="My Server"
                      value={config.name}
                      onChange={(e) => updateConfig({ name: e.target.value })}
                    />
                  </div>
                  <div className="space-y-2">
                    <Label htmlFor="protocol">Protocol</Label>
                    <Select
                      value={config.protocol}
                      onValueChange={(value: ConnectionConfig['protocol']) => {
                        const validAuthMethods = getAuthMethods(value);
                        const currentAuthValid = validAuthMethods.includes(config.authMethod);
                        updateConfig({
                          protocol: value,
                          port: getDefaultPort(value),
                          ...(!currentAuthValid && { authMethod: validAuthMethods[0] }),
                          ...(value !== 'FTP' && { ftpsEnabled: undefined }),
                        });
                      }}
                    >
                      <SelectTrigger>
                        <SelectValue />
                      </SelectTrigger>
                      <SelectContent>
                        <SelectItem value="SSH">SSH</SelectItem>
                        <SelectItem value="SFTP">SFTP</SelectItem>
                        <SelectItem value="FTP">FTP</SelectItem>
                        <SelectItem value="RDP">RDP</SelectItem>
                        <SelectItem value="VNC">VNC</SelectItem>
                        <SelectItem value="Telnet">Telnet</SelectItem>
                        <SelectItem value="Raw">Raw</SelectItem>
                        <SelectItem value="Serial">Serial</SelectItem>
                      </SelectContent>
                    </Select>
                  </div>
                </div>

                <div className="grid grid-cols-3 gap-4">
                  <div className="col-span-2 space-y-2">
                    <Label htmlFor="host">Host</Label>
                    <Input
                      id="host"
                      placeholder="192.168.1.100 or example.com"
                      value={config.host}
                      onChange={(e) => updateConfig({ host: e.target.value })}
                    />
                  </div>
                  <div className="space-y-2">
                    <Label htmlFor="port">Port</Label>
                    <Input
                      id="port"
                      type="number"
                      value={config.port}
                      onChange={(e) => updateConfig({ port: parseInt(e.target.value) || 22 })}
                    />
                  </div>
                </div>

                {/* Username — hidden for VNC (VNC uses password-only auth) */}
                {config.protocol !== 'VNC' && (
                  <div className="space-y-2">
                    <Label htmlFor="username">Username</Label>
                    <Input
                      id="username"
                      placeholder="root"
                      value={config.username}
                      onChange={(e) => updateConfig({ username: e.target.value })}
                    />
                  </div>
                )}

                {/* RDP-specific: domain and resolution */}
                {config.protocol === 'RDP' && (
                  <div className="grid grid-cols-2 gap-4">
                    <div className="space-y-2">
                      <Label htmlFor="rdp-domain">Domain (optional)</Label>
                      <Input
                        id="rdp-domain"
                        placeholder="WORKGROUP"
                        value={config.domain || ''}
                        onChange={(e) => updateConfig({ domain: e.target.value })}
                      />
                    </div>
                    <div className="space-y-2">
                      <Label>Display Resolution</Label>
                      <Select
                        value={config.rdpResolution || 'fit'}
                        onValueChange={(value) => updateConfig({ rdpResolution: value as ConnectionConfig['rdpResolution'] })}
                      >
                        <SelectTrigger>
                          <SelectValue />
                        </SelectTrigger>
                        <SelectContent>
                          <SelectItem value="fit">Fit to Window</SelectItem>
                          <SelectItem value="1024x768">1024×768</SelectItem>
                          <SelectItem value="1280x720">1280×720 (HD)</SelectItem>
                          <SelectItem value="1920x1080">1920×1080 (Full HD)</SelectItem>
                        </SelectContent>
                      </Select>
                    </div>
                  </div>
                )}

                {/* VNC-specific: color depth */}
                {config.protocol === 'VNC' && (
                  <div className="space-y-2">
                    <Label>Color Depth</Label>
                    <Select
                      value={config.vncColorDepth || '24'}
                      onValueChange={(value) => updateConfig({ vncColorDepth: value as ConnectionConfig['vncColorDepth'] })}
                    >
                      <SelectTrigger>
                        <SelectValue />
                      </SelectTrigger>
                      <SelectContent>
                        <SelectItem value="24">True Color (24-bit)</SelectItem>
                        <SelectItem value="16">High Color (16-bit)</SelectItem>
                        <SelectItem value="8">256 Colors (8-bit)</SelectItem>
                      </SelectContent>
                    </Select>
                  </div>
                )}

                {/* Desktop protocol info */}
                {isDesktopProtocol(config.protocol) && (
                  <div className="p-4 bg-muted rounded-lg">
                    <div className="flex items-center gap-2 mb-2">
                      <Monitor className="h-4 w-4" />
                      <span className="font-medium">Remote Desktop</span>
                    </div>
                    <p className="text-sm text-muted-foreground">
                      {config.protocol === 'RDP'
                        ? 'RDP connects to Windows Remote Desktop. Requires NLA-compatible credentials.'
                        : 'VNC connects to any host running a VNC server. Uses password-only authentication.'}
                    </p>
                  </div>
                )}
              </CardContent>
            </Card>
          </TabsContent>

          <TabsContent value="authentication" className="flex-1 overflow-y-auto px-6 py-4 space-y-4 mt-0">
            <Card>
              <CardHeader>
                <CardTitle className="flex items-center gap-2">
                  <Shield className="h-4 w-4" />
                  Authentication Method
                </CardTitle>
                <CardDescription>
                  Choose how to authenticate with the remote server.
                </CardDescription>
              </CardHeader>
              <CardContent className="space-y-4">
                <div className="space-y-2">
                  <Label>Authentication Method</Label>
                  <Select
                    value={config.authMethod}
                    onValueChange={(value: ConnectionConfig['authMethod']) => updateConfig({ authMethod: value })}
                  >
                    <SelectTrigger>
                      <SelectValue />
                    </SelectTrigger>
                    <SelectContent>
                      {getAuthMethods(config.protocol).map((method) => (
                        <SelectItem key={method} value={method}>
                          {method === 'password' ? 'Password' :
                           method === 'publickey' ? 'Public Key' :
                           method === 'keyboard-interactive' ? 'Keyboard Interactive' :
                           method === 'anonymous' ? 'Anonymous' : method}
                        </SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                </div>

                {config.authMethod === 'password' && (
                  <div className="space-y-2">
                    <Label htmlFor="password">Password</Label>
                    <Input
                      id="password"
                      type="password"
                      placeholder="Enter password"
                      value={config.password}
                      onChange={(e) => {
                        // User is editing the field — once they touch it,
                        // they own it. Clear the "came from keychain" marker
                        // so the Forget button stops showing.
                        if (loadedFromKeychain) setLoadedFromKeychain(false);
                        updateConfig({ password: e.target.value });
                      }}
                    />
                    {loadedFromKeychain && (
                      <p className="text-xs text-muted-foreground flex items-center gap-1">
                        <Key className="h-3 w-3" />
                        Loaded from Keychain
                      </p>
                    )}
                  </div>
                )}

                {config.authMethod === 'publickey' && (
                  <div className="space-y-4">
                    <div className="space-y-2">
                      <Label htmlFor="private-key">Private Key File</Label>
                      <Input
                        id="private-key"
                        placeholder="~/.ssh/id_rsa or ~/.ssh/id_ed25519"
                        value={config.privateKeyPath}
                        onChange={(e) => updateConfig({ privateKeyPath: e.target.value })}
                      />
                      <p className="text-xs text-muted-foreground">
                        Common locations: ~/.ssh/id_rsa, ~/.ssh/id_ed25519, ~/.ssh/id_ecdsa
                      </p>
                    </div>
                    <div className="space-y-2">
                      <Label htmlFor="passphrase">Passphrase (optional)</Label>
                      <Input
                        id="passphrase"
                        type="password"
                        placeholder="Enter passphrase if key is encrypted"
                        value={config.passphrase}
                        onChange={(e) => {
                          if (loadedFromKeychain) setLoadedFromKeychain(false);
                          updateConfig({ passphrase: e.target.value });
                        }}
                      />
                      {loadedFromKeychain && (
                        <p className="text-xs text-muted-foreground flex items-center gap-1">
                          <Key className="h-3 w-3" />
                          Loaded from Keychain
                        </p>
                      )}
                    </div>
                  </div>
                )}

                {/* Keychain controls — only shown on platforms where the
                    backend can actually access a system keychain (macOS today)
                    and only for auth methods that have a secret to store. */}
                {keychainSupported === true
                  && (config.authMethod === 'password' || config.authMethod === 'publickey')
                  && currentCredentialKind() !== null && (
                  <>
                    <Separator />
                    <div className="flex items-center justify-between">
                      <div className="space-y-0.5">
                        <Label htmlFor="save-to-keychain">Save to Keychain</Label>
                        <p className="text-sm text-muted-foreground">
                          Store the {config.authMethod === 'password' ? 'password' : 'key passphrase'} in the system keychain instead of in local storage.
                        </p>
                      </div>
                      <Switch
                        id="save-to-keychain"
                        checked={saveToKeychain}
                        onCheckedChange={setSaveToKeychain}
                      />
                    </div>
                    {loadedFromKeychain && (
                      <Button
                        variant="ghost"
                        size="sm"
                        className="self-start"
                        onClick={handleForgetCredential}
                        type="button"
                      >
                        <XIcon className="h-3.5 w-3.5 mr-1" />
                        Forget saved credential
                      </Button>
                    )}
                  </>
                )}

                {config.authMethod === 'anonymous' && (
                  <div className="p-4 bg-muted rounded-lg">
                    <p className="text-sm text-muted-foreground">
                      Anonymous authentication will connect without credentials. Some FTP servers allow public access this way.
                    </p>
                  </div>
                )}

                {config.protocol === 'FTP' && (
                  <>
                    <Separator />
                    <div className="flex items-center justify-between">
                      <div className="space-y-0.5">
                        <Label>Enable FTPS (FTP over TLS)</Label>
                        <p className="text-sm text-muted-foreground">
                          Encrypt the FTP connection using TLS for improved security
                        </p>
                      </div>
                      <Switch
                        checked={config.ftpsEnabled ?? false}
                        onCheckedChange={(checked) => updateConfig({ ftpsEnabled: checked })}
                      />
                    </div>
                  </>
                )}

                <div className="p-4 bg-muted rounded-lg">
                  <div className="flex items-center gap-2 mb-2">
                    <Key className="h-4 w-4" />
                    <span className="font-medium">Security Note</span>
                  </div>
                  <p className="text-sm text-muted-foreground">
                    {config.authMethod === 'password' ? (
                      <>For production environments, we recommend using public key authentication instead of passwords for enhanced security.</>
                    ) : config.authMethod === 'anonymous' ? (
                      <>Anonymous connections are not encrypted. Use FTPS for secure file transfers when possible.</>
                    ) : (
                      <>Public key authentication is more secure than passwords. R-Shell supports RSA, Ed25519, and ECDSA keys.</>
                    )}
                  </p>
                </div>
              </CardContent>
            </Card>
          </TabsContent>

          <TabsContent value="proxy" className="flex-1 overflow-y-auto px-6 py-4 space-y-4 mt-0">
            <Card>
              <CardHeader>
                <CardTitle className="flex items-center gap-2">
                  <Network className="h-4 w-4" />
                  Proxy Settings
                </CardTitle>
                <CardDescription>
                  Configure proxy settings if you need to connect through a proxy server.
                </CardDescription>
              </CardHeader>
              <CardContent className="space-y-4">
                <div className="space-y-2">
                  <Label>Proxy Type</Label>
                  <Select
                    value={config.proxyType}
                    onValueChange={(value: string) => updateConfig({ proxyType: value as ConnectionConfig['proxyType'] })}
                  >
                    <SelectTrigger>
                      <SelectValue />
                    </SelectTrigger>
                    <SelectContent>
                      <SelectItem value="none">No Proxy</SelectItem>
                      <SelectItem value="http">HTTP Proxy</SelectItem>
                      <SelectItem value="socks4">SOCKS4</SelectItem>
                      <SelectItem value="socks5">SOCKS5</SelectItem>
                    </SelectContent>
                  </Select>
                </div>

                {config.proxyType !== 'none' && (
                  <>
                    <div className="grid grid-cols-3 gap-4">
                      <div className="col-span-2 space-y-2">
                        <Label htmlFor="proxy-host">Proxy Host</Label>
                        <Input
                          id="proxy-host"
                          placeholder="proxy.example.com"
                          value={config.proxyHost}
                          onChange={(e) => updateConfig({ proxyHost: e.target.value })}
                        />
                      </div>
                      <div className="space-y-2">
                        <Label htmlFor="proxy-port">Proxy Port</Label>
                        <Input
                          id="proxy-port"
                          type="number"
                          value={config.proxyPort}
                          onChange={(e) => updateConfig({ proxyPort: parseInt(e.target.value) || 8080 })}
                        />
                      </div>
                    </div>

                    <div className="grid grid-cols-2 gap-4">
                      <div className="space-y-2">
                        <Label htmlFor="proxy-username">Proxy Username</Label>
                        <Input
                          id="proxy-username"
                          placeholder="Optional"
                          onChange={(e) => updateConfig({ proxyUsername: e.target.value })}
                        />
                      </div>
                      <div className="space-y-2">
                        <Label htmlFor="proxy-password">Proxy Password</Label>
                        <Input
                          id="proxy-password"
                          type="password"
                          placeholder="Optional"
                          value={config.proxyPassword}
                          onChange={(e) => updateConfig({ proxyPassword: e.target.value })}
                        />
                      </div>
                    </div>
                  </>
                )}
              </CardContent>
            </Card>
          </TabsContent>

          <TabsContent value="advanced" className="flex-1 overflow-y-auto px-6 py-4 space-y-4 mt-0">
            {(() => {
              const hiddenFields = getHiddenFields(config.protocol);
              const isCompHidden = hiddenFields.includes('compression');
              const isKaHidden = hiddenFields.includes('keepAliveInterval');
              const isAllHidden = isCompHidden && isKaHidden;

              if (isAllHidden) {
                return (
                  <Card>
                    <CardHeader>
                      <CardTitle className="flex items-center gap-2">
                        <TerminalIcon className="h-4 w-4" />
                        Advanced Options
                      </CardTitle>
                      <CardDescription>
                        No advanced options are available for {config.protocol} connections.
                      </CardDescription>
                    </CardHeader>
                  </Card>
                );
              }

              return (
                <Card>
                  <CardHeader>
                    <CardTitle className="flex items-center gap-2">
                      <TerminalIcon className="h-4 w-4" />
                      Advanced SSH Options
                    </CardTitle>
                    <CardDescription>
                      Fine-tune SSH connection behavior and performance.
                    </CardDescription>
                  </CardHeader>
                  <CardContent className="space-y-4">
                    <div className="space-y-4">
                      {!isCompHidden && (
                        <div className="flex items-center justify-between">
                          <div className="space-y-0.5">
                            <Label>Enable Compression</Label>
                            <p className="text-sm text-muted-foreground">
                              Compress data to improve performance over slow connections
                            </p>
                          </div>
                          <Switch
                            checked={config.compression}
                            onCheckedChange={(checked) => updateConfig({ compression: checked })}
                          />
                        </div>
                      )}

                      {!isCompHidden && !isKaHidden && <Separator />}

                      {!isKaHidden && (
                        <>
                          <div className="flex items-center justify-between">
                            <div className="space-y-0.5">
                              <Label>Keep Alive</Label>
                              <p className="text-sm text-muted-foreground">
                                Send keep-alive messages to prevent connection timeout
                              </p>
                            </div>
                            <Switch
                              checked={config.keepAlive}
                              onCheckedChange={(checked) => updateConfig({ keepAlive: checked })}
                            />
                          </div>

                          {config.keepAlive && (
                            <div className="grid grid-cols-2 gap-4 ml-4">
                              <div className="space-y-2">
                                <Label htmlFor="keep-alive-interval">Interval (seconds)</Label>
                                <Input
                                  id="keep-alive-interval"
                                  type="number"
                                  value={config.keepAliveInterval}
                                  onChange={(e) => updateConfig({ keepAliveInterval: parseInt(e.target.value) || 60 })}
                                />
                              </div>
                              <div className="space-y-2">
                                <Label htmlFor="max-count">Max Count</Label>
                                <Input
                                  id="max-count"
                                  type="number"
                                  value={config.serverAliveCountMax}
                                  onChange={(e) => updateConfig({ serverAliveCountMax: parseInt(e.target.value) || 3 })}
                                />
                              </div>
                            </div>
                          )}
                        </>
                      )}
                    </div>
                  </CardContent>
                </Card>
              );
            })()}
          </TabsContent>


        </Tabs>

        <DialogFooter className="px-6 py-4 border-t bg-muted/30 flex-col sm:flex-col">
          <div className="flex flex-col gap-3 w-full">
            {/* Save as Connection Option - Only show for new connections */}
            {!editingConnection && (
              <div className="flex items-center justify-between">
                <div className="flex items-center gap-2">
                  <Switch
                    id="save-connection"
                    checked={saveAsConnection}
                    onCheckedChange={setSaveAsConnection}
                  />
                  <Label htmlFor="save-connection" className="text-sm cursor-pointer">
                    Save as persistent connection
                  </Label>
                </div>
                {saveAsConnection && (
                  <Select value={connectionFolder} onValueChange={setConnectionFolder}>
                    <SelectTrigger className="w-[200px] h-8">
                      <SelectValue placeholder="Select folder" />
                    </SelectTrigger>
                    <SelectContent>
                      {availableFolders.length > 0 ? (
                        availableFolders.map((folder) => (
                          <SelectItem key={folder} value={folder}>
                            {folder}
                          </SelectItem>
                        ))
                      ) : (
                        <SelectItem value="All Connections">All Connections</SelectItem>
                      )}
                    </SelectContent>
                  </Select>
                )}
              </div>
            )}

            {/* Action Buttons */}
            <div className="flex justify-end gap-2">
              <Button
                variant={isConnecting ? "destructive" : "outline"}
                onClick={handleCancelConnectionAttempt}
                disabled={isCancelling}
              >
                {isConnecting ? (isCancelling ? 'Cancelling...' : 'Stop') : 'Cancel'}
              </Button>
              <Button onClick={handleConnect} disabled={isConnecting || isCancelling} className="min-w-[140px]">
                {isConnecting ? 'Connecting...' : editingConnection ? 'Update & Connect' : 'Connect'}
              </Button>
            </div>
          </div>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
