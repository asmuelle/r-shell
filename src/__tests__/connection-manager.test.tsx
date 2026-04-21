import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import {
  ConnectionManager,
  decodeDraggedConnectionNode,
  encodeDraggedConnectionNode,
  moveDraggedConnectionNodeToFolder,
} from '../components/connection-manager';
import { ConnectionStorageManager } from '../lib/connection-storage';

const toast = vi.hoisted(() => ({
  success: vi.fn(),
  error: vi.fn(),
}));

vi.mock('sonner', () => ({
  toast,
}));

describe('ConnectionManager drag and drop', () => {
  afterEach(() => {
    cleanup();
  });

  beforeEach(() => {
    localStorage.clear();
    ConnectionStorageManager.initialize();
    toast.success.mockReset();
    toast.error.mockReset();
  });

  it('encodes and decodes dragged nodes safely', () => {
    const encoded = encodeDraggedConnectionNode({
      id: 'conn-1',
      name: 'Analytics',
      type: 'connection',
      path: undefined,
    });

    expect(decodeDraggedConnectionNode(encoded)).toEqual({
      id: 'conn-1',
      name: 'Analytics',
      type: 'connection',
      path: undefined,
    });
    expect(decodeDraggedConnectionNode('not-json')).toBeNull();
  });

  it('moves a connection into a folder on drop', () => {
    ConnectionStorageManager.createFolder('Servers', 'All Connections');
    const connection = ConnectionStorageManager.saveConnection({
      name: 'Analytics',
      host: 'analytics.kwiqly.com',
      port: 22,
      username: 'root',
      protocol: 'SSH',
      folder: 'All Connections',
      authMethod: 'publickey',
      privateKeyPath: '~/.ssh/id_rsa',
    });

    const result = moveDraggedConnectionNodeToFolder(
      {
        id: connection.id,
        name: connection.name,
        type: 'connection',
      },
      {
        id: 'folder-servers',
        name: 'Servers',
        type: 'folder',
        path: 'All Connections/Servers',
      },
    );

    expect(result).toEqual({
      status: 'success',
      message: 'Moved "Analytics" to "Servers"',
    });
    expect(ConnectionStorageManager.getConnection(connection.id)?.folder).toBe(
      'All Connections/Servers',
    );
  });

  it('moves a folder recursively with its subfolders and connections', () => {
    ConnectionStorageManager.createFolder('Source', 'All Connections');
    ConnectionStorageManager.createFolder('Nested', 'All Connections/Source');
    ConnectionStorageManager.createFolder('Target', 'All Connections');

    const rootConnection = ConnectionStorageManager.saveConnection({
      name: 'Root Connection',
      host: 'root.example.com',
      port: 22,
      username: 'root',
      protocol: 'SSH',
      folder: 'All Connections/Source',
    });
    const nestedConnection = ConnectionStorageManager.saveConnection({
      name: 'Nested Connection',
      host: 'nested.example.com',
      port: 22,
      username: 'root',
      protocol: 'SSH',
      folder: 'All Connections/Source/Nested',
    });

    const result = moveDraggedConnectionNodeToFolder(
      {
        id: 'folder-source',
        name: 'Source',
        type: 'folder',
        path: 'All Connections/Source',
      },
      {
        id: 'folder-target',
        name: 'Target',
        type: 'folder',
        path: 'All Connections/Target',
      },
    );

    expect(result).toEqual({
      status: 'success',
      message: 'Moved folder "Source" to "Target"',
    });
    expect(ConnectionStorageManager.getConnection(rootConnection.id)?.folder).toBe(
      'All Connections/Target/Source',
    );
    expect(ConnectionStorageManager.getConnection(nestedConnection.id)?.folder).toBe(
      'All Connections/Target/Source/Nested',
    );
    expect(
      ConnectionStorageManager.getFolders().some(
        (folder) => folder.path === 'All Connections/Target/Source/Nested',
      ),
    ).toBe(true);
    expect(
      ConnectionStorageManager.getFolders().some(
        (folder) => folder.path === 'All Connections/Source',
      ),
    ).toBe(false);
  });

  it('drops a connection onto a folder in the rendered tree', () => {
    const targetFolder = ConnectionStorageManager.createFolder('Servers', 'All Connections');
    const connection = ConnectionStorageManager.saveConnection({
      name: 'Analytics',
      host: 'analytics.kwiqly.com',
      port: 22,
      username: 'root',
      protocol: 'SSH',
      folder: 'All Connections',
      authMethod: 'publickey',
      privateKeyPath: '~/.ssh/id_rsa',
    });

    const { unmount } = render(
      <ConnectionManager
        onConnectionSelect={vi.fn()}
        selectedConnectionId={null}
      />,
    );

    const dataTransfer = createDataTransfer();

    fireEvent.dragStart(screen.getByLabelText('Drag connection Analytics'), { dataTransfer });
    fireEvent.dragEnter(screen.getByTestId(`folder-drop-target-${targetFolder.id}`), { dataTransfer });
    fireEvent.dragOver(screen.getByTestId(`folder-drop-target-${targetFolder.id}`), { dataTransfer });
    fireEvent.drop(screen.getByTestId(`folder-drop-target-${targetFolder.id}`), { dataTransfer });

    expect(ConnectionStorageManager.getConnection(connection.id)?.folder).toBe(
      'All Connections/Servers',
    );

    unmount();
  });
});

function createDataTransfer() {
  const store = new Map<string, string>();

  return {
    effectAllowed: 'move',
    dropEffect: 'move',
    setData(type: string, value: string) {
      store.set(type, value);
    },
    getData(type: string) {
      return store.get(type) ?? '';
    },
  };
}
