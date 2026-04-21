import React, { useState, useEffect } from 'react';
import { ChevronRight, ChevronDown, Folder, FolderOpen, Monitor, Server, HardDrive, Plus, Pencil, Copy, Trash2, FolderPlus, FolderEdit, GripVertical } from 'lucide-react';
import { Button } from './ui/button';
import { Badge } from './ui/badge';
import { Separator } from './ui/separator';
import { Input } from './ui/input';
import { Label } from './ui/label';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from './ui/select';
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from './ui/dialog';
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
import { ConnectionStorageManager } from '../lib/connection-storage';
import {
  ContextMenu,
  ContextMenuContent,
  ContextMenuItem,
  ContextMenuSeparator,
  ContextMenuTrigger,
} from './ui/context-menu';
import { toast } from 'sonner';

interface ConnectionNode {
  id: string;
  name: string;
  type: 'folder' | 'connection';
  path?: string; // For folders
  protocol?: string;
  host?: string;
  port?: number;
  username?: string;
  profileId?: string;
  lastConnected?: string;
  isConnected?: boolean;
  children?: ConnectionNode[];
  isExpanded?: boolean;
}

interface ConnectionManagerProps {
  onConnectionSelect: (connection: ConnectionNode) => void;
  onConnectionConnect?: (connection: ConnectionNode) => void; // Connect to connection (double-click or context menu)
  selectedConnectionId: string | null;
  activeConnections?: Set<string>; // Set of currently active connection IDs
  onNewConnection?: () => void; // Callback to open connection dialog
  onEditConnection?: (connection: ConnectionNode) => void; // Callback to edit connection
  onDeleteConnection?: (connectionId: string) => void; // Callback to delete connection
  onDuplicateConnection?: (connection: ConnectionNode) => void; // Callback to duplicate connection
}

const CONNECTION_MANAGER_DRAG_MIME = 'application/x-r-shell-connection-node';

interface DraggedConnectionNode {
  id: string;
  name: string;
  type: 'folder' | 'connection';
  path?: string;
}

type DropTargetFolderNode = Pick<ConnectionNode, 'id' | 'name' | 'type' | 'path'>;

type MoveDraggedNodeResult =
  | { status: 'success'; message: string }
  | { status: 'error'; message: string; description?: string }
  | { status: 'noop' };

const EMPTY_ACTIVE_CONNECTIONS = new Set<string>();

export function encodeDraggedConnectionNode(node: ConnectionNode): string {
  return JSON.stringify({
    id: node.id,
    name: node.name,
    type: node.type,
    path: node.path,
  } satisfies DraggedConnectionNode);
}

export function decodeDraggedConnectionNode(raw: string): DraggedConnectionNode | null {
  if (!raw) {
    return null;
  }

  try {
    const parsed = JSON.parse(raw) as Partial<DraggedConnectionNode>;
    if (
      typeof parsed.id !== 'string' ||
      typeof parsed.name !== 'string' ||
      (parsed.type !== 'folder' && parsed.type !== 'connection')
    ) {
      return null;
    }

    return {
      id: parsed.id,
      name: parsed.name,
      type: parsed.type,
      path: typeof parsed.path === 'string' ? parsed.path : undefined,
    };
  } catch {
    return null;
  }
}

export function moveDraggedConnectionNodeToFolder(
  droppedNode: DraggedConnectionNode,
  targetNode: DropTargetFolderNode,
): MoveDraggedNodeResult {
  if (targetNode.type !== 'folder' || !targetNode.path) {
    return { status: 'noop' };
  }

  if (droppedNode.id === targetNode.id) {
    return { status: 'noop' };
  }

  if (
    droppedNode.type === 'folder' &&
    droppedNode.path &&
    targetNode.path.startsWith(`${droppedNode.path}/`)
  ) {
    return {
      status: 'error',
      message: 'Cannot move folder into its own subfolder',
    };
  }

  if (droppedNode.type === 'connection') {
    const connection = ConnectionStorageManager.getConnection(droppedNode.id);
    if (!connection) {
      return { status: 'error', message: 'Failed to move connection' };
    }

    if (connection.folder === targetNode.path) {
      return { status: 'noop' };
    }

    if (!ConnectionStorageManager.moveConnection(droppedNode.id, targetNode.path)) {
      return { status: 'error', message: 'Failed to move connection' };
    }

    return {
      status: 'success',
      message: `Moved "${droppedNode.name}" to "${targetNode.name}"`,
    };
  }

  if (!droppedNode.path) {
    return {
      status: 'error',
      message: 'Failed to Move Folder',
      description: 'Dragged folder has no source path.',
    };
  }

  try {
    const oldPath = droppedNode.path;
    const newPath = `${targetNode.path}/${droppedNode.name}`;
    if (oldPath === newPath) {
      return { status: 'noop' };
    }

    const existingFolder = ConnectionStorageManager.getFolders().find(
      (folder) => folder.path === newPath,
    );
    if (existingFolder) {
      return {
        status: 'error',
        message: `Folder "${droppedNode.name}" already exists in "${targetNode.name}"`,
      };
    }

    const connections = ConnectionStorageManager.getConnectionsByFolderRecursive(oldPath);
    const subfolders = ConnectionStorageManager.getSubfoldersRecursive(oldPath);

    ConnectionStorageManager.createFolder(droppedNode.name, targetNode.path);

    subfolders.forEach((subfolder) => {
      const relativePath = subfolder.path.substring(oldPath.length + 1);
      const parts = relativePath.split('/');
      const subfolderName = parts[parts.length - 1];
      const subfolderParentPath =
        parts.length > 1 ? `${newPath}/${parts.slice(0, -1).join('/')}` : newPath;

      ConnectionStorageManager.createFolder(subfolderName, subfolderParentPath);
    });

    connections.forEach((connection) => {
      const movedPath =
        connection.folder === oldPath
          ? newPath
          : `${newPath}/${connection.folder!.substring(oldPath.length + 1)}`;
      ConnectionStorageManager.moveConnection(connection.id, movedPath);
    });

    ConnectionStorageManager.deleteFolder(oldPath, true);

    return {
      status: 'success',
      message: `Moved folder "${droppedNode.name}" to "${targetNode.name}"`,
    };
  } catch (error) {
    return {
      status: 'error',
      message: 'Failed to Move Folder',
      description:
        error instanceof Error ? error.message : 'Unable to move folder to new location.',
    };
  }
}

export function ConnectionManager({
  onConnectionSelect,
  onConnectionConnect,
  selectedConnectionId,
  activeConnections,
  onNewConnection,
  onEditConnection,
  onDeleteConnection,
  onDuplicateConnection
}: ConnectionManagerProps) {
  const activeConnectionIds = activeConnections ?? EMPTY_ACTIVE_CONNECTIONS;

  // Load connections from storage
  const loadConnections = (): ConnectionNode[] => {
    const tree = ConnectionStorageManager.buildConnectionTree(activeConnectionIds);
    return tree.length > 0 ? tree : [];
  };

  const [connections, setConnections] = useState<ConnectionNode[]>(loadConnections());

  // Folder management state
  const [newFolderDialogOpen, setNewFolderDialogOpen] = useState(false);
  const [newFolderName, setNewFolderName] = useState('');
  const [newFolderParentPath, setNewFolderParentPath] = useState<string | undefined>(undefined);
  const [deleteFolderDialogOpen, setDeleteFolderDialogOpen] = useState(false);
  const [folderToDelete, setFolderToDelete] = useState<{ path: string; name: string } | null>(null);
  const [renameFolderDialogOpen, setRenameFolderDialogOpen] = useState(false);
  const [folderToRename, setFolderToRename] = useState<{ path: string; name: string; parentPath?: string } | null>(null);
  const [renameFolderNewName, setRenameFolderNewName] = useState('');
  const [moveDialogOpen, setMoveDialogOpen] = useState(false);
  const [moveTargetPath, setMoveTargetPath] = useState('All Connections');
  const [itemToMove, setItemToMove] = useState<DraggedConnectionNode | null>(null);
  const [dragOverFolderId, setDragOverFolderId] = useState<string | null>(null);

  // Drag and drop state
  const [draggedItem, setDraggedItem] = useState<{ node: ConnectionNode; type: 'connection' | 'folder' } | null>(null);

  // Reload connections when active connections change
  useEffect(() => {
    setConnections(loadConnections());
  }, [activeConnectionIds]);

  // Handle connection deletion
  const handleDelete = (connectionId: string) => {
    if (ConnectionStorageManager.deleteConnection(connectionId)) {
      setConnections(loadConnections());
      toast.success('Connection deleted');
      if (onDeleteConnection) {
        onDeleteConnection(connectionId);
      }
    } else {
      toast.error('Failed to delete connection');
    }
  };

  // Handle connection duplication
  const handleDuplicate = (node: ConnectionNode) => {
    if (node.type === 'connection' && node.host) {
      // Load the full connection data to get authentication credentials
      const connectionData = ConnectionStorageManager.getConnection(node.id);
      if (connectionData) {
        const duplicated = ConnectionStorageManager.saveConnection({
          name: `${node.name} (Copy)`,
          host: node.host,
          port: node.port || 22,
          username: node.username || '',
          protocol: node.protocol || 'SSH',
          folder: connectionData.folder || 'All Connections',
          // Copy authentication credentials
          authMethod: connectionData.authMethod,
          password: connectionData.password,
          privateKeyPath: connectionData.privateKeyPath,
          passphrase: connectionData.passphrase,
        });
        setConnections(loadConnections());
        toast.success(`Duplicated: ${duplicated.name}`);
        if (onDuplicateConnection) {
          onDuplicateConnection(node);
        }
      }
    }
  };

  // Handle creating new folder
  const handleCreateFolder = () => {
    if (!newFolderName.trim()) {
      toast.error('Folder name cannot be empty');
      return;
    }

    try {
      ConnectionStorageManager.createFolder(newFolderName.trim(), newFolderParentPath);
      setConnections(loadConnections());
      toast.success(`Folder "${newFolderName}" created`);
      setNewFolderDialogOpen(false);
      setNewFolderName('');
      setNewFolderParentPath(undefined);
    } catch (_error) {
      toast.error('Failed to create folder');
    }
  };

  // Handle deleting folder
  const handleDeleteFolder = () => {
    if (!folderToDelete) return;

    if (ConnectionStorageManager.deleteFolder(folderToDelete.path, true)) {
      setConnections(loadConnections());
      toast.success(`Folder "${folderToDelete.name}" deleted`);
      setDeleteFolderDialogOpen(false);
      setFolderToDelete(null);
    } else {
      toast.error('Failed to delete folder');
    }
  };

  // Open new folder dialog
  const openNewFolderDialog = (parentPath?: string) => {
    setNewFolderParentPath(parentPath);
    setNewFolderDialogOpen(true);
  };

  // Handle renaming folder
  const handleRenameFolder = () => {
    if (!folderToRename || !renameFolderNewName.trim()) {
      toast.error('Folder name cannot be empty');
      return;
    }

    try {
      const oldPath = folderToRename.path;
      const newName = renameFolderNewName.trim();
      const newPath = folderToRename.parentPath
        ? `${folderToRename.parentPath}/${newName}`
        : newName;

      // Get all connections in this folder and subfolders
      const allConnections = ConnectionStorageManager.getConnectionsByFolderRecursive(oldPath);

      // Get all subfolders
      const subfolders = ConnectionStorageManager.getSubfoldersRecursive(oldPath);

      // Create new folder first
      ConnectionStorageManager.createFolder(newName, folderToRename.parentPath);

      // Recreate all subfolders with new parent path
      subfolders.forEach(subfolder => {
        const relativePath = subfolder.path.substring(oldPath.length + 1); // Remove old parent path
        const _newSubfolderPath = `${newPath}/${relativePath}`;
        const parts = relativePath.split('/');
        const subfolderName = parts[parts.length - 1];
        const subfolderParentPath = parts.length > 1
          ? `${newPath}/${parts.slice(0, -1).join('/')}`
          : newPath;

        ConnectionStorageManager.createFolder(subfolderName, subfolderParentPath);
      });

      // Move all connections to new paths
      allConnections.forEach(connection => {
        let newConnectionPath: string;
        if (connection.folder === oldPath) {
          // Connection directly in the renamed folder
          newConnectionPath = newPath;
        } else {
          // Connection in a subfolder - update the path
          const relativePath = connection.folder!.substring(oldPath.length + 1);
          newConnectionPath = `${newPath}/${relativePath}`;
        }
        ConnectionStorageManager.moveConnection(connection.id, newConnectionPath);
      });

      // Delete old folder and all subfolders
      ConnectionStorageManager.deleteFolder(oldPath, true);

      setConnections(loadConnections());
      toast.success(`Folder renamed to "${newName}"`);
      setRenameFolderDialogOpen(false);
      setFolderToRename(null);
      setRenameFolderNewName('');
    } catch (error) {
      console.error('Rename folder error:', error);
      toast.error('Failed to Rename Folder', {
        description: error instanceof Error ? error.message : 'Unable to rename folder.',
      });
    }
  };

  // Open rename folder dialog
  const openRenameFolderDialog = (path: string, name: string, parentPath?: string) => {
    setFolderToRename({ path, name, parentPath });
    setRenameFolderNewName(name);
    setRenameFolderDialogOpen(true);
  };

  // Open delete folder dialog
  const openDeleteFolderDialog = (path: string, name: string) => {
    setFolderToDelete({ path, name });
    setDeleteFolderDialogOpen(true);
  };

  const getMoveTargetFolders = (item: DraggedConnectionNode | null) => {
    const folders = [
      { name: 'All Connections', path: 'All Connections' },
      ...ConnectionStorageManager.getValidFolders()
        .filter((folder) => folder.path !== 'All Connections')
        .map((folder) => ({ name: folder.name, path: folder.path })),
    ];

    if (!item) {
      return folders;
    }

    if (item.type === 'connection') {
      const currentFolder =
        ConnectionStorageManager.getConnection(item.id)?.folder || 'All Connections';
      return folders.filter((folder) => folder.path !== currentFolder);
    }

    return folders.filter((folder) => {
      if (!item.path) {
        return false;
      }

      return (
        folder.path !== item.path &&
        !folder.path.startsWith(`${item.path}/`)
      );
    });
  };

  const openMoveDialog = (node: ConnectionNode) => {
    const item: DraggedConnectionNode = {
      id: node.id,
      name: node.name,
      type: node.type,
      path: node.path,
    };
    const availableTargets = getMoveTargetFolders(item);
    setItemToMove(item);
    setMoveTargetPath(availableTargets[0]?.path || 'All Connections');
    setMoveDialogOpen(true);
  };

  const handleMoveToFolder = () => {
    if (!itemToMove) {
      return;
    }

    const targetName =
      moveTargetPath === 'All Connections'
        ? 'All Connections'
        : moveTargetPath.split('/').pop() || moveTargetPath;
    const result = moveDraggedConnectionNodeToFolder(itemToMove, {
      id: `move-target:${moveTargetPath}`,
      name: targetName,
      type: 'folder',
      path: moveTargetPath,
    });

    if (result.status === 'success') {
      setConnections(loadConnections());
      toast.success(result.message);
      setMoveDialogOpen(false);
      setItemToMove(null);
      return;
    }

    if (result.status === 'error') {
      toast.error(result.message, result.description ? { description: result.description } : undefined);
      return;
    }

    setMoveDialogOpen(false);
    setItemToMove(null);
  };

  const getDraggedNodeFromEvent = (e: Pick<React.DragEvent, 'dataTransfer'>) =>
    decodeDraggedConnectionNode(e.dataTransfer.getData(CONNECTION_MANAGER_DRAG_MIME)) ||
    decodeDraggedConnectionNode(e.dataTransfer.getData('text/plain')) ||
    (draggedItem
      ? {
          id: draggedItem.node.id,
          name: draggedItem.node.name,
          type: draggedItem.type,
          path: draggedItem.node.path,
        }
      : null);

  const canDropIntoFolder = (droppedNode: DraggedConnectionNode | null, targetNode: ConnectionNode) => {
    if (!droppedNode || targetNode.type !== 'folder' || !targetNode.path) {
      return false;
    }

    if (droppedNode.id === targetNode.id) {
      return false;
    }

    if (
      droppedNode.type === 'folder' &&
      droppedNode.path &&
      targetNode.path.startsWith(`${droppedNode.path}/`)
    ) {
      return false;
    }

    return true;
  };

  // Drag and drop handlers
  const handleDragStart = (e: React.DragEvent, node: ConnectionNode) => {
    setDraggedItem({ node, type: node.type });
    setDragOverFolderId(null);
    e.dataTransfer.effectAllowed = 'move';
    const payload = encodeDraggedConnectionNode(node);
    e.dataTransfer.setData(CONNECTION_MANAGER_DRAG_MIME, payload);
    e.dataTransfer.setData('text/plain', payload);
  };

  const handleFolderDragEnter = (e: React.DragEvent, targetNode: ConnectionNode) => {
    const droppedNode = getDraggedNodeFromEvent(e);
    if (!canDropIntoFolder(droppedNode, targetNode)) {
      return;
    }

    e.preventDefault();
    e.stopPropagation();
    e.dataTransfer.dropEffect = 'move';
    setDragOverFolderId(targetNode.id);
  };

  const handleFolderDragOver = (e: React.DragEvent, targetNode: ConnectionNode) => {
    const droppedNode = getDraggedNodeFromEvent(e);
    if (!canDropIntoFolder(droppedNode, targetNode)) {
      return;
    }

    e.preventDefault();
    e.stopPropagation();
    e.dataTransfer.dropEffect = 'move';
    setDragOverFolderId(targetNode.id);
  };

  const handleFolderDragLeave = (e: React.DragEvent, targetNode: ConnectionNode) => {
    e.stopPropagation();

    const nextTarget = e.relatedTarget as Node | null;
    if (nextTarget && e.currentTarget.contains(nextTarget)) {
      return;
    }

    if (dragOverFolderId === targetNode.id) {
      setDragOverFolderId(null);
    }
  };

  const handleDrop = (e: React.DragEvent, targetNode: ConnectionNode) => {
    e.preventDefault();
    e.stopPropagation();
    setDragOverFolderId(null);

    const droppedNode = getDraggedNodeFromEvent(e);

    if (!droppedNode) return;

    // Can only drop into folders
    if (targetNode.type !== 'folder' || !targetNode.path) return;

    // Don't drop into itself
    if (droppedNode.id === targetNode.id) return;

    // Don't drop folder into its own child
    if (
      droppedNode.type === 'folder' &&
      droppedNode.path &&
      targetNode.path.startsWith(`${droppedNode.path}/`)
    ) {
      toast.error('Cannot move folder into its own subfolder');
      return;
    }

    const result = moveDraggedConnectionNodeToFolder(droppedNode, targetNode);
    if (result.status === 'success') {
      setConnections(loadConnections());
      toast.success(result.message);
    } else if (result.status === 'error') {
      toast.error(result.message, result.description ? { description: result.description } : undefined);
    }

    setDraggedItem(null);
  };

  const handleDragEnd = () => {
    setDraggedItem(null);
    setDragOverFolderId(null);
  };

  // Find the selected connection details
  const getSelectedConnection = (nodes: ConnectionNode[]): ConnectionNode | null => {
    for (const node of nodes) {
      if (node.id === selectedConnectionId) {
        return node;
      }
      if (node.children) {
        const found = getSelectedConnection(node.children);
        if (found) return found;
      }
    }
    return null;
  };

  const selectedConnection = getSelectedConnection(connections);

  const toggleExpanded = (nodeId: string) => {
    const updateNode = (nodes: ConnectionNode[]): ConnectionNode[] => {
      return nodes.map(node => {
        if (node.id === nodeId) {
          return { ...node, isExpanded: !node.isExpanded };
        }
        if (node.children) {
          return { ...node, children: updateNode(node.children) };
        }
        return node;
      });
    };
    setConnections(updateNode(connections));
  };

  const getIcon = (node: ConnectionNode) => {
    if (node.type === 'folder') {
      return node.isExpanded ? <FolderOpen className="w-4 h-4" /> : <Folder className="w-4 h-4" />;
    }

    switch (node.protocol) {
      case 'SSH':
        return <Server className="w-4 h-4 text-green-500" />;
      case 'CMD':
      case 'PowerShell':
      case 'Shell':
        return <Monitor className="w-4 h-4 text-blue-500" />;
      case 'WSL':
        return <HardDrive className="w-4 h-4 text-orange-500" />;
      default:
        return <Monitor className="w-4 h-4" />;
    }
  };

  const renderNode = (node: ConnectionNode, level: number = 0) => {
    const isSelected = selectedConnectionId === node.id;
    const isConnected = node.type === 'connection' && node.isConnected;
    const isDragging = draggedItem?.node.id === node.id;
    const isDropTarget = node.type === 'folder' && dragOverFolderId === node.id;
    const canDragNode = node.type === 'connection' || node.path !== 'All Connections';

    const handleNodeClick = () => {
      // Always select the node first
      onConnectionSelect(node);

      // Then toggle folder expansion if it's a folder
      if (node.type === 'folder') {
        toggleExpanded(node.id);
      }
    };

    const handleNodeDoubleClick = () => {
      if (node.type === 'connection') {
        // Double click to connect
        if (onConnectionConnect) {
          onConnectionConnect(node);
        } else {
          onConnectionSelect(node);
        }
      }
    };

    const nodeContent = (
      <div
        className={`group flex items-center gap-2 px-2 py-1 cursor-pointer ${
          isSelected ? 'bg-accent' : ''
        } ${isDragging ? 'opacity-50' : 'hover:bg-accent'} ${
          isDropTarget ? 'bg-accent ring-1 ring-primary/60' : ''
        }`}
        style={{ paddingLeft: `${level * 16 + 8}px` }}
        onClick={handleNodeClick}
        onDoubleClick={handleNodeDoubleClick}
      >
        {node.type === 'folder' && (
          <Button variant="ghost" size="sm" className="p-0 h-4 w-4">
            {node.isExpanded ?
              <ChevronDown className="w-3 h-3" /> :
              <ChevronRight className="w-3 h-3" />
            }
          </Button>
        )}
        {node.type === 'connection' && <div className="w-4" />}

        <div
          className={`flex h-4 w-4 items-center justify-center rounded-sm ${
            canDragNode
              ? 'cursor-grab text-muted-foreground hover:text-foreground active:cursor-grabbing'
              : 'text-muted-foreground/30'
          }`}
          aria-label={canDragNode ? `Drag ${node.type} ${node.name}` : undefined}
          title={canDragNode ? `Drag ${node.type}` : undefined}
          draggable={canDragNode}
          onDragStart={canDragNode ? (e) => handleDragStart(e, node) : undefined}
          onDragEnd={canDragNode ? handleDragEnd : undefined}
          onMouseDown={(e) => e.stopPropagation()}
          onClick={(e) => e.stopPropagation()}
        >
          <GripVertical className="w-3 h-3" />
        </div>

        <div className="relative">
          {getIcon(node)}
          {isConnected && (
            <div className="absolute -bottom-0.5 -right-0.5 w-2 h-2 bg-green-500 rounded-full border border-card" />
          )}
        </div>
        <span className="text-sm flex-1">{node.name}</span>
      </div>
    );

    return (
      <div
        key={node.id}
        data-testid={node.type === 'folder' ? `folder-drop-target-${node.id}` : undefined}
        onDragEnter={node.type === 'folder' ? (e) => handleFolderDragEnter(e, node) : undefined}
        onDragOver={node.type === 'folder' ? (e) => handleFolderDragOver(e, node) : undefined}
        onDragLeave={node.type === 'folder' ? (e) => handleFolderDragLeave(e, node) : undefined}
        onDrop={node.type === 'folder' ? (e) => handleDrop(e, node) : undefined}
      >
        {node.type === 'connection' ? (
          <ContextMenu onOpenChange={(open) => {
            if (open) {
              // Select the connection when context menu opens (right-click)
              onConnectionSelect(node);
            }
          }}>
            <ContextMenuTrigger asChild>
              {nodeContent}
            </ContextMenuTrigger>
            <ContextMenuContent>
              <ContextMenuItem
                onClick={() => {
                  if (onConnectionConnect) {
                    onConnectionConnect(node);
                  } else {
                    onConnectionSelect(node);
                  }
                }}
              >
                {isConnected ? 'Switch to Connection' : 'Connect'}
              </ContextMenuItem>
              {onEditConnection && (
                <ContextMenuItem
                  onClick={() => onEditConnection(node)}
                >
                  <Pencil className="w-4 h-4 mr-2" />
                  Edit
                </ContextMenuItem>
              )}
              <ContextMenuItem
                onClick={() => handleDuplicate(node)}
              >
                <Copy className="w-4 h-4 mr-2" />
                Duplicate
              </ContextMenuItem>
              <ContextMenuItem
                onClick={() => openMoveDialog(node)}
              >
                <Folder className="w-4 h-4 mr-2" />
                Move to Folder
              </ContextMenuItem>
              <ContextMenuSeparator />
              <ContextMenuItem
                onClick={() => handleDelete(node.id)}
                className="text-destructive"
              >
                <Trash2 className="w-4 h-4 mr-2" />
                Delete
              </ContextMenuItem>
            </ContextMenuContent>
          </ContextMenu>
        ) : node.type === 'folder' ? (
          <ContextMenu onOpenChange={(open) => {
            if (open && node.type === 'folder') {
              // Select the folder when context menu opens (right-click)
              onConnectionSelect(node);
            }
          }}>
            <ContextMenuTrigger asChild>
              {nodeContent}
            </ContextMenuTrigger>
            <ContextMenuContent>
              <ContextMenuItem
                onClick={() => openNewFolderDialog(node.path)}
              >
                <FolderPlus className="w-4 h-4 mr-2" />
                New Subfolder
              </ContextMenuItem>
              {node.path !== 'All Connections' && (
                <>
                  <ContextMenuItem
                    onClick={() => openMoveDialog(node)}
                  >
                    <Folder className="w-4 h-4 mr-2" />
                    Move to Folder
                  </ContextMenuItem>
                  <ContextMenuItem
                    onClick={() => {
                      const folders = ConnectionStorageManager.getFolders();
                      const folder = folders.find(f => f.path === node.path);
                      openRenameFolderDialog(node.path!, node.name, folder?.parentPath);
                    }}
                  >
                    <FolderEdit className="w-4 h-4 mr-2" />
                    Rename Folder
                  </ContextMenuItem>
                  <ContextMenuSeparator />
                  <ContextMenuItem
                    onClick={() => openDeleteFolderDialog(node.path!, node.name)}
                    className="text-destructive"
                  >
                    <Trash2 className="w-4 h-4 mr-2" />
                    Delete Folder
                  </ContextMenuItem>
                </>
              )}
            </ContextMenuContent>
          </ContextMenu>
        ) : (
          nodeContent
        )}

        {node.type === 'folder' && node.isExpanded && node.children && (
          <div>
            {node.children.map(child => renderNode(child, level + 1))}
          </div>
        )}
      </div>
    );
  };

  return (
    <>
    <div className="bg-card border-r border-border h-full flex flex-col">
      {/* Connection Browser */}
      <div className="flex-1 min-h-0 flex flex-col">
        <div className="p-3 border-b border-border flex items-center justify-between">
          <h3 className="font-medium">Connection Manager</h3>
          <Button
            variant="ghost"
            size="sm"
            onClick={() => openNewFolderDialog()}
            className="h-7 w-7 p-0"
          >
            <FolderPlus className="w-4 h-4" />
          </Button>
        </div>
        <div className="flex-1 overflow-auto">
          {connections.length === 0 ? (
            <div className="flex flex-col items-center justify-center h-full p-4 text-center">
              <p className="text-sm text-muted-foreground mb-4">No connections yet</p>
              {onNewConnection && (
                <Button onClick={onNewConnection} size="sm" variant="outline">
                  <Plus className="w-4 h-4 mr-2" />
                  New Connection
                </Button>
              )}
            </div>
          ) : (
            connections.map(connection => renderNode(connection))
          )}
        </div>
      </div>

      {/* Connection Details */}
      <div className="border-t border-border">
        <div className="p-3">
          <h3 className="font-medium text-sm mb-3">Connection Details</h3>

          {!selectedConnection || selectedConnection.type === 'folder' ? (
            <p className="text-sm text-muted-foreground">No connection selected</p>
          ) : (
            <div className="space-y-3">
              <div className="space-y-2">
                <div className="flex items-center justify-between">
                  <span className="text-xs font-medium">Name</span>
                  <span className="text-xs">{selectedConnection.name}</span>
                </div>

                <div className="flex items-center justify-between">
                  <span className="text-xs font-medium">Type</span>
                  <Badge variant="outline" className="text-xs py-0 px-1 h-5">
                    {selectedConnection.protocol}
                  </Badge>
                </div>

                <div className="flex items-center justify-between">
                  <span className="text-xs font-medium">Status</span>
                  <div className="flex items-center gap-2">
                    <div className={`w-2 h-2 rounded-full ${selectedConnection.isConnected ? 'bg-green-500' : 'bg-gray-500'}`} />
                    <span className="text-xs">{selectedConnection.isConnected ? 'Connected' : 'Disconnected'}</span>
                  </div>
                </div>

                {selectedConnection.lastConnected && (
                  <div className="flex items-center justify-between">
                    <span className="text-xs font-medium">Last Connected</span>
                    <span className="text-xs">
                      {new Date(selectedConnection.lastConnected).toLocaleString()}
                    </span>
                  </div>
                )}
              </div>

              {selectedConnection.host && (
                <>
                  <Separator />
                  <div className="space-y-2">
                    <div className="flex items-center justify-between">
                      <span className="text-xs font-medium">Host</span>
                      <span className="text-xs">{selectedConnection.host}</span>
                    </div>

                    {selectedConnection.username && (
                      <div className="flex items-center justify-between">
                        <span className="text-xs font-medium">Username</span>
                        <span className="text-xs">{selectedConnection.username}</span>
                      </div>
                    )}

                    <div className="flex items-center justify-between">
                      <span className="text-xs font-medium">Port</span>
                      <span className="text-xs">
                        {selectedConnection.port || (selectedConnection.protocol === 'SSH' ? 22 : 23)}
                      </span>
                    </div>
                  </div>
                </>
              )}

              <Separator />

              <div className="space-y-2">
                <div className="flex items-center justify-between">
                  <span className="text-xs font-medium">Protocol</span>
                  <span className="text-xs">{selectedConnection.protocol}</span>
                </div>

                <div className="flex items-center justify-between">
                  <span className="text-xs font-medium">Description</span>
                  <span className="text-xs text-muted-foreground">-</span>
                </div>
              </div>
            </div>
          )}
        </div>
      </div>
    </div>
    
    {/* New Folder Dialog */}
    <Dialog open={newFolderDialogOpen} onOpenChange={setNewFolderDialogOpen}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Create New Folder</DialogTitle>
          <DialogDescription>
            Create a new folder to organize your connections.
            {newFolderParentPath && ` Parent: ${newFolderParentPath}`}
          </DialogDescription>
        </DialogHeader>
        <div className="space-y-4 py-4">
          <div className="space-y-2">
            <Label htmlFor="folder-name">Folder Name</Label>
            <Input
              id="folder-name"
              placeholder="Enter folder name"
              value={newFolderName}
              onChange={(e) => setNewFolderName(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === 'Enter') {
                  handleCreateFolder();
                }
              }}
            />
          </div>
        </div>
        <DialogFooter>
          <Button variant="outline" onClick={() => setNewFolderDialogOpen(false)}>
            Cancel
          </Button>
          <Button onClick={handleCreateFolder}>Create</Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
    
    {/* Delete Folder Confirmation Dialog */}
    <AlertDialog open={deleteFolderDialogOpen} onOpenChange={setDeleteFolderDialogOpen}>
      <AlertDialogContent>
        <AlertDialogHeader>
          <AlertDialogTitle>Delete Folder?</AlertDialogTitle>
          <AlertDialogDescription>
            Are you sure you want to delete the folder "{folderToDelete?.name}"? 
            This will also delete all connections and subfolders within it.
            This action cannot be undone.
          </AlertDialogDescription>
        </AlertDialogHeader>
        <AlertDialogFooter>
          <AlertDialogCancel>Cancel</AlertDialogCancel>
          <AlertDialogAction onClick={handleDeleteFolder} className="bg-destructive text-destructive-foreground hover:bg-destructive/90">
            Delete
          </AlertDialogAction>
        </AlertDialogFooter>
      </AlertDialogContent>
    </AlertDialog>
    
    {/* Rename Folder Dialog */}
    <Dialog open={renameFolderDialogOpen} onOpenChange={setRenameFolderDialogOpen}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Rename Folder</DialogTitle>
          <DialogDescription>
            Rename the folder "{folderToRename?.name}".
          </DialogDescription>
        </DialogHeader>
        <div className="space-y-4 py-4">
          <div className="space-y-2">
            <Label htmlFor="rename-folder-name">Folder Name</Label>
            <Input
              id="rename-folder-name"
              placeholder="Enter new folder name"
              value={renameFolderNewName}
              onChange={(e) => setRenameFolderNewName(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === 'Enter') {
                  handleRenameFolder();
                }
              }}
            />
          </div>
        </div>
        <DialogFooter>
          <Button variant="outline" onClick={() => setRenameFolderDialogOpen(false)}>
            Cancel
          </Button>
          <Button onClick={handleRenameFolder}>Rename</Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>

    <Dialog
      open={moveDialogOpen}
      onOpenChange={(open) => {
        setMoveDialogOpen(open);
        if (!open) {
          setItemToMove(null);
        }
      }}
    >
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Move to Folder</DialogTitle>
          <DialogDescription>
            {itemToMove
              ? `Move "${itemToMove.name}" to another folder.`
              : 'Choose the destination folder.'}
          </DialogDescription>
        </DialogHeader>
        <div className="space-y-4 py-4">
          <div className="space-y-2">
            <Label htmlFor="move-folder-target">Destination Folder</Label>
            <Select value={moveTargetPath} onValueChange={setMoveTargetPath}>
              <SelectTrigger id="move-folder-target">
                <SelectValue placeholder="Select destination folder" />
              </SelectTrigger>
              <SelectContent>
                {getMoveTargetFolders(itemToMove).map((folder) => (
                  <SelectItem key={folder.path} value={folder.path}>
                    {folder.path}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
            {itemToMove && getMoveTargetFolders(itemToMove).length === 0 && (
              <p className="text-sm text-muted-foreground">
                No valid destination folders are available.
              </p>
            )}
          </div>
        </div>
        <DialogFooter>
          <Button
            variant="outline"
            onClick={() => {
              setMoveDialogOpen(false);
              setItemToMove(null);
            }}
          >
            Cancel
          </Button>
          <Button
            onClick={handleMoveToFolder}
            disabled={!itemToMove || getMoveTargetFolders(itemToMove).length === 0}
          >
            Move
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
    </>
  );
}
