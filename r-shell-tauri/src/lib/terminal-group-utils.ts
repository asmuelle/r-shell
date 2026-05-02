import type { TerminalTab } from './terminal-group-types';

const FILE_BROWSER_PROTOCOLS = new Set(['SFTP', 'FTP']);

export function isFileBrowserProtocol(protocol?: string | null): boolean {
  return protocol ? FILE_BROWSER_PROTOCOLS.has(protocol.toUpperCase()) : false;
}

export function isFileBrowserTab(tab: TerminalTab | null | undefined): boolean {
  return tab?.tabType === 'file-browser' || isFileBrowserProtocol(tab?.protocol);
}

export function isOpenSshTerminalTab(tab: TerminalTab | null | undefined): boolean {
  if (!tab) return false;
  const isTerminalTab = tab.tabType === undefined || tab.tabType === 'terminal';
  const protocol = tab.protocol || 'SSH';

  return isTerminalTab && protocol === 'SSH' && tab.connectionStatus === 'connected';
}

/**
 * Compute the display name for a tab, appending a numeric suffix when multiple
 * tabs in the same group share the same base connection profile.
 *
 * - Single tab from a profile → "Server Name"
 * - Multiple tabs from same profile → "Server Name (1)", "Server Name (2)", etc.
 */
export function getTabDisplayName(tab: TerminalTab, allTabsInGroup: TerminalTab[]): string {
  const baseId = tab.originalConnectionId || tab.id;

  const siblings = allTabsInGroup.filter(t => {
    const tBaseId = t.originalConnectionId || t.id;
    return tBaseId === baseId;
  });

  if (siblings.length <= 1) return tab.name;

  const index = siblings.indexOf(tab) + 1;
  return `${tab.name} (${index})`;
}
