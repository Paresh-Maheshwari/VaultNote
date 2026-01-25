// ============================================================================
// VAULTNOTE BOOKMARK SYNC - BACKGROUND SCRIPT
// ============================================================================
//
// Service worker for Chrome/Firefox/Edge extension that handles:
// - Auto-sync VaultNote bookmarks to browser (30s interval)
// - Context menu for saving current page
// - Communication with VaultNote app via HTTP API (port 52525)
// - Folder management and organization
// - Optional API key authentication
//
// Sync Flow:
// 1. Poll VaultNote app every 30 seconds
// 2. Compare bookmarks with local browser storage
// 3. Create/update/delete browser bookmarks as needed
// 4. Handle manual saves from popup/context menu
//
// ============================================================================

// VaultNote Bookmark Sync - Background Script
// Sync: VaultNote → Browser (auto), Browser → VaultNote (manual via popup/context menu)

const DEFAULT_FOLDERS = ['Browser Sync', 'Work', 'Personal', 'Research', 'Reading List'];

let FLUTTER_APP_URL = 'http://127.0.0.1:52525';
let SYNC_INTERVAL = 30000;
let SYNC_FOLDERS = [];
let EXCLUDE_FOLDERS = [];
let API_KEY = '';
let syncTimer = null;

// URLs being created by sync (to prevent loop)
const creatingUrls = new Set();

// Get headers with optional API key
function getHeaders() {
  const headers = { 'Content-Type': 'application/json' };
  if (API_KEY) headers['X-API-Key'] = API_KEY;
  return headers;
}

// Load settings
async function loadSettings() {
  const settings = await chrome.storage.sync.get({
    host: '127.0.0.1',
    port: 52525,
    syncInterval: 30,
    defaultFolder: 'Browser Sync',
    folders: [...DEFAULT_FOLDERS],
    syncFolders: [],
    apiKey: ''
  });
  // excludeFolders stored locally per browser
  const local = await chrome.storage.local.get({ excludeFolders: [] });
  FLUTTER_APP_URL = `http://${settings.host}:${settings.port}`;
  SYNC_INTERVAL = settings.syncInterval * 1000;
  SYNC_FOLDERS = settings.syncFolders || [];
  EXCLUDE_FOLDERS = local.excludeFolders || [];
  API_KEY = settings.apiKey || '';
  return { ...settings, excludeFolders: EXCLUDE_FOLDERS };
}

// Initialize on install
chrome.runtime.onInstalled.addListener(async () => {
  await init();
});

// Initialize on startup
chrome.runtime.onStartup.addListener(async () => {
  await init();
});

// Initialize when service worker starts (handles restart case)
init();

async function init() {
  const settings = await loadSettings();
  createContextMenus(settings.folders);
  startBackgroundSync();
}

// Create context menus with folder submenus
function createContextMenus(folders) {
  chrome.contextMenus.removeAll(() => {
    chrome.contextMenus.create({
      id: 'save-to-vaultnote',
      title: 'Save to VaultNote',
      contexts: ['page', 'link', 'selection']
    });
    folders.forEach(folder => {
      chrome.contextMenus.create({
        id: 'folder-' + folder,
        parentId: 'save-to-vaultnote',
        title: '📁 ' + folder,
        contexts: ['page', 'link', 'selection']
      });
    });
  });
}

// Context menu - save to VaultNote
chrome.contextMenus.onClicked.addListener(async (info, tab) => {
  const url = info.linkUrl || tab.url;
  const notes = info.selectionText || '';
  
  if (info.menuItemId === 'save-to-vaultnote') {
    const settings = await loadSettings();
    await saveToVaultNote(url, tab.title, notes, settings.defaultFolder);
  } else if (info.menuItemId.startsWith('folder-')) {
    const folder = info.menuItemId.replace('folder-', '');
    await saveToVaultNote(url, tab.title, notes, folder);
  }
});

// Save bookmark to VaultNote (or queue if offline)
async function saveToVaultNote(url, title, notes = '', folder = 'Browser Sync') {
  // Validate URL
  if (!url || typeof url !== 'string') return false;
  try {
    const urlObj = new URL(url);
    if (!['http:', 'https:'].includes(urlObj.protocol)) return false;
  } catch {
    return false;
  }
  
  // Sanitize inputs
  const sanitizedTitle = (title || 'Untitled').substring(0, 500);
  const sanitizedNotes = (notes || '').substring(0, 5000);
  const sanitizedFolder = (folder || 'Browser Sync').substring(0, 100);
  
  const bookmark = { 
    url, 
    title: sanitizedTitle, 
    description: sanitizedNotes, 
    folder: sanitizedFolder, 
    tags: ['browser-sync'], 
    source: 'extension' 
  };
  
  try {
    const response = await fetch(`${FLUTTER_APP_URL}/bookmark`, {
      method: 'POST',
      headers: getHeaders(),
      body: JSON.stringify(bookmark)
    });
    if (response.ok) {
      return true;
    }
  } catch (e) {
    // Queue for later
    const { offlineQueue = [] } = await chrome.storage.local.get('offlineQueue');
    if (!offlineQueue.some(b => b.url === url) || notes) {
      offlineQueue.push(bookmark);
      await chrome.storage.local.set({ offlineQueue });
    }
  }
  return false;
}

// Process offline queue
async function processOfflineQueue() {
  const { offlineQueue = [] } = await chrome.storage.local.get('offlineQueue');
  if (offlineQueue.length === 0) return;
  
  const remaining = [];
  
  for (const bookmark of offlineQueue) {
    try {
      const res = await fetch(`${FLUTTER_APP_URL}/bookmark`, {
        method: 'POST',
        headers: getHeaders(),
        body: JSON.stringify(bookmark)
      });
      if (!res.ok) remaining.push(bookmark);
    } catch (e) {
      remaining.push(bookmark);
    }
  }
  
  await chrome.storage.local.set({ offlineQueue: remaining });
}

// Get bookmarks from VaultNote
async function getVaultNoteBookmarks() {
  try {
    const res = await fetch(`${FLUTTER_APP_URL}/bookmarks`, { headers: getHeaders() });
    if (res.ok) return await res.json();
  } catch (e) { /* VaultNote offline */ }
  return [];
}

// Sync: VaultNote → Browser (add new only, no move/delete to prevent loops)
async function syncFromVaultNote() {
  await processOfflineQueue();
  
  try {
    let vaultNoteBookmarks = await getVaultNoteBookmarks();
    if (vaultNoteBookmarks.length === 0) return;
    
    const totalCount = vaultNoteBookmarks.length;
    
    // Filter by sync folders if specified
    if (SYNC_FOLDERS.length > 0) {
      vaultNoteBookmarks = vaultNoteBookmarks.filter(b => 
        SYNC_FOLDERS.some(f => b.folder === f || b.folder.startsWith(f + '/'))
      );
    }
    
    // Exclude folders (don't sync these back to this browser)
    if (EXCLUDE_FOLDERS.length > 0) {
      const beforeExclude = vaultNoteBookmarks.length;
      vaultNoteBookmarks = vaultNoteBookmarks.filter(b => 
        !EXCLUDE_FOLDERS.some(f => b.folder === f || b.folder.startsWith(f + '/'))
      );
    }
    
    const browserBookmarks = await getAllBrowserBookmarks();
    const existingUrls = new Set(browserBookmarks.map(b => b.url));
    
    // Only add new bookmarks (no move, no delete)
    for (const bookmark of vaultNoteBookmarks) {
      if (!existingUrls.has(bookmark.url)) {
        creatingUrls.add(bookmark.url);
        const folderId = await getOrCreateFolder(bookmark.folder || 'VaultNote');
        await chrome.bookmarks.create({
          parentId: folderId,
          title: bookmark.title,
          url: bookmark.url
        });
        setTimeout(() => creatingUrls.delete(bookmark.url), 1000);
      }
    }
  } catch (e) { /* Sync failed, will retry */ }
}

// Get all browser bookmarks
async function getAllBrowserBookmarks() {
  const bookmarks = [];
  function traverse(nodes, path = '') {
    for (const node of nodes) {
      if (node.url) {
        bookmarks.push({ ...node, folder: path || 'Bookmarks' });
      } else if (node.children) {
        traverse(node.children, path ? `${path}/${node.title}` : node.title);
      }
    }
  }
  const tree = await chrome.bookmarks.getTree();
  traverse(tree);
  return bookmarks;
}

// Get or create nested folder
async function getOrCreateFolder(folderPath) {
  const tree = await chrome.bookmarks.getTree();
  const parts = folderPath.split('/').filter(p => p);
  
  const bookmarkBar = tree[0].children.find(c => 
    c.title === 'Bookmarks bar' || c.title === 'Favorites bar'
  ) || tree[0].children[0];
  
  let parentId = bookmarkBar.id;
  
  for (const part of parts) {
    const children = await chrome.bookmarks.getChildren(parentId);
    const existing = children.find(n => n.title === part && !n.url);
    if (existing) {
      parentId = existing.id;
    } else {
      const newFolder = await chrome.bookmarks.create({ parentId, title: part });
      parentId = newFolder.id;
    }
  }
  
  return parentId;
}

// Start auto-sync
function startBackgroundSync() {
  if (syncTimer) clearInterval(syncTimer);
  
  if (SYNC_INTERVAL > 0) {
    setTimeout(syncFromVaultNote, 5000);
    syncTimer = setInterval(syncFromVaultNote, SYNC_INTERVAL);
  }
}

// Message handler
chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message.action === 'syncNow') {
    syncFromVaultNote().then(() => sendResponse({ success: true }));
    return true;
  }
  
  if (message.action === 'queueBookmark') {
    (async () => {
      const b = message.bookmark;
      const { offlineQueue = [] } = await chrome.storage.local.get('offlineQueue');
      if (!offlineQueue.some(q => q.url === b.url) || b.description) {
        offlineQueue.push(b);
        await chrome.storage.local.set({ offlineQueue });
      }
      sendResponse({ success: true });
    })();
    return true;
  }
  
  if (message.action === 'updateSettings') {
    FLUTTER_APP_URL = `http://${message.settings.host || '127.0.0.1'}:${message.settings.port}`;
    SYNC_INTERVAL = message.settings.syncInterval * 1000;
    SYNC_FOLDERS = message.settings.syncFolders || [];
    EXCLUDE_FOLDERS = message.settings.excludeFolders || [];
    API_KEY = message.settings.apiKey || '';
    if (message.settings.folders) createContextMenus(message.settings.folders);
    startBackgroundSync();
    sendResponse({ success: true });
  }
});
