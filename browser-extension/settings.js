// ============================================================================
// VAULTNOTE EXTENSION SETTINGS
// ============================================================================
//
// Extension settings page for configuring VaultNote bookmark sync:
// - VaultNote app connection (host, port)
// - Sync interval configuration
// - Folder management (create, organize, sync preferences)
// - API key authentication setup
// - Import/export browser bookmarks
// - Dark mode toggle
//
// Settings stored in chrome.storage.sync for cross-device sync.
// Communicates with VaultNote app via HTTP API on configured port.
//
// ============================================================================

// VaultNote Extension Settings

let settings = {
  host: '127.0.0.1',
  port: 52525,
  syncInterval: 30,
  defaultFolder: 'Browser Sync',
  folders: [],
  syncFolders: [],
  apiKey: '',
  darkMode: false
};

// Custom confirm modal
function showConfirm(title, msg) {
  const modal = document.getElementById('confirmModal');
  document.getElementById('confirmTitle').textContent = title;
  document.getElementById('confirmMsg').textContent = msg;
  modal.style.display = 'flex';
  return new Promise(resolve => {
    document.getElementById('confirmNo').onclick = () => { modal.style.display = 'none'; resolve(false); };
    document.getElementById('confirmYes').onclick = () => { modal.style.display = 'none'; resolve(true); };
  });
}

// Get headers with optional API key (reads from input field for live updates)
function getHeaders() {
  const headers = { 'Content-Type': 'application/json' };
  const apiKey = document.getElementById('apiKey')?.value?.trim() || settings.apiKey;
  if (apiKey) headers['X-API-Key'] = apiKey;
  return headers;
}

let excludeFolders = []; // Stored locally per browser
let vaultNoteFolders = []; // Folders from API

// Load settings
document.addEventListener('DOMContentLoaded', async () => {
  const stored = await chrome.storage.sync.get({
    host: '127.0.0.1',
    port: 52525,
    syncInterval: 30,
    defaultFolder: 'Browser Sync',
    folders: ['Browser Sync', 'Work', 'Personal', 'Research', 'Reading List'],
    syncFolders: [],
    apiKey: '',
    darkMode: window.matchMedia('(prefers-color-scheme: dark)').matches
  });
  
  // Load excludeFolders from local storage (per browser)
  const local = await chrome.storage.local.get({ excludeFolders: [] });
  excludeFolders = local.excludeFolders || [];
  
  settings = stored;
  
  document.getElementById('host').value = settings.host;
  document.getElementById('port').value = settings.port;
  document.getElementById('syncInterval').value = settings.syncInterval;
  document.getElementById('apiKey').value = settings.apiKey || '';
  
  if (settings.darkMode) document.body.classList.add('dark');
  
  renderFolders();
  setupTabs();
  checkConnection();
  fetchVaultNoteFolders();
  loadAboutInfo();
});

// Tab switching
function setupTabs() {
  document.querySelectorAll('.tab').forEach(tab => {
    tab.addEventListener('click', () => {
      document.querySelectorAll('.tab').forEach(t => t.classList.remove('active'));
      document.querySelectorAll('.tab-content').forEach(c => c.classList.remove('active'));
      tab.classList.add('active');
      document.getElementById('tab-' + tab.dataset.tab).classList.add('active');
      // Hide save button on Import and About tabs
      const hideOnTabs = ['import', 'about'];
      document.getElementById('saveBtn').style.display = hideOnTabs.includes(tab.dataset.tab) ? 'none' : 'block';
    });
  });
}

// Check connection
async function checkConnection() {
  const status = document.getElementById('connectionStatus');
  const host = document.getElementById('host').value.trim() || '127.0.0.1';
  const port = document.getElementById('port').value || 52525;
  const url = `http://${host}:${port}/ping`;
  
  try {
    const res = await fetch(url, { signal: AbortSignal.timeout(3000), headers: getHeaders() });
    if (res.ok) {
      status.innerHTML = '<span style="color: var(--success)">✓ Connected to VaultNote</span>';
    } else if (res.status === 401) {
      status.innerHTML = '<span style="color: var(--error)">✗ Invalid API key</span>';
    } else {
      status.innerHTML = '<span style="color: var(--error)">✗ Server error</span>';
    }
  } catch (e) {
    status.innerHTML = '<span style="color: var(--error)">✗ Cannot connect - is VaultNote running?</span>';
  }
}

// Fetch folders from VaultNote API
async function fetchVaultNoteFolders() {
  const host = document.getElementById('host').value.trim() || '127.0.0.1';
  const port = document.getElementById('port').value || 52525;
  const url = `http://${host}:${port}/folders`;
  
  try {
    const res = await fetch(url, { signal: AbortSignal.timeout(3000), headers: getHeaders() });
    if (res.ok) {
      vaultNoteFolders = await res.json();
      renderSyncFolders();
      renderVaultNoteFolderDropdown();
    }
  } catch (e) {}
}

// Render VaultNote folders dropdown for quick add
function renderVaultNoteFolderDropdown() {
  const select = document.getElementById('vaultNoteFolderSelect');
  if (!select) return;
  select.innerHTML = '<option value="">-- Select from VaultNote --</option>' +
    vaultNoteFolders.filter(f => !settings.folders.includes(f)).map(f => 
      `<option value="${f}">${f}</option>`
    ).join('');
}

// Render exclude folder checkboxes
function renderSyncFolders() {
  const excludeGrid = document.getElementById('excludeFolderGrid');
  if (!excludeGrid) return;
  
  if (vaultNoteFolders.length === 0) {
    excludeGrid.innerHTML = '<div class="no-folders">No folders in VaultNote</div>';
    return;
  }
  
  const esc = s => s.replace(/&/g, '&amp;').replace(/"/g, '&quot;').replace(/</g, '&lt;');
  
  excludeGrid.innerHTML = vaultNoteFolders.map(folder => `
    <label class="folder-item">
      <input type="checkbox" value="${esc(folder)}" ${excludeFolders.includes(folder) ? 'checked' : ''}>
      <span>${esc(folder)}</span>
    </label>
  `).join('');
}

// Render quick save folders
function renderFolders() {
  const folderList = document.getElementById('folderList');
  const defaultFolderSelect = document.getElementById('defaultFolder');
  const importFolderSelect = document.getElementById('importFolder');
  
  folderList.innerHTML = settings.folders.map(folder => `
    <div class="folder-tag">
      <span>📁 ${folder}</span>
      <span class="remove" data-folder="${folder}">×</span>
    </div>
  `).join('');
  
  defaultFolderSelect.innerHTML = settings.folders.map(folder => 
    `<option value="${folder}" ${folder === settings.defaultFolder ? 'selected' : ''}>${folder}</option>`
  ).join('');
  
  importFolderSelect.innerHTML = '<option value="">Keep original folders</option>' + 
    settings.folders.map(folder => `<option value="${folder}">${folder}</option>`).join('') +
    '<option value="__custom__">Custom folder...</option>';
  
  folderList.querySelectorAll('.remove').forEach(btn => {
    btn.addEventListener('click', () => {
      const folder = btn.dataset.folder;
      if (settings.folders.length > 1) {
        settings.folders = settings.folders.filter(f => f !== folder);
        if (settings.defaultFolder === folder) settings.defaultFolder = settings.folders[0];
        renderFolders();
      }
    });
  });
}

// Show/hide custom folder input
document.getElementById('importFolder').addEventListener('change', (e) => {
  document.getElementById('customFolderGroup').style.display = e.target.value === '__custom__' ? 'block' : 'none';
});

// Theme toggle
document.getElementById('themeBtn').addEventListener('click', async () => {
  settings.darkMode = !settings.darkMode;
  document.body.classList.toggle('dark', settings.darkMode);
  await chrome.storage.sync.set({ darkMode: settings.darkMode });
});

// Add folder from VaultNote dropdown
document.getElementById('addFromVaultNoteBtn').addEventListener('click', () => {
  const select = document.getElementById('vaultNoteFolderSelect');
  const name = select.value;
  if (name && !settings.folders.includes(name)) {
    settings.folders.push(name);
    renderFolders();
    renderVaultNoteFolderDropdown();
  }
});

// Add folder manually
document.getElementById('addFolderBtn').addEventListener('click', () => {
  const input = document.getElementById('newFolder');
  const name = input.value.trim();
  if (name && !settings.folders.includes(name)) {
    settings.folders.push(name);
    input.value = '';
    renderFolders();
  }
});

document.getElementById('newFolder').addEventListener('keypress', (e) => {
  if (e.key === 'Enter') document.getElementById('addFolderBtn').click();
});

// Refresh folders
document.getElementById('refreshFolders').addEventListener('click', () => {
  fetchVaultNoteFolders();
});

// Save settings
document.getElementById('saveBtn').addEventListener('click', async () => {
  const host = document.getElementById('host').value.trim() || '127.0.0.1';
  const port = parseInt(document.getElementById('port').value, 10);
  
  // Validate host (IP or hostname)
  const ipRegex = /^(\d{1,3}\.){3}\d{1,3}$/;
  const hostnameRegex = /^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)*$/;
  if (!ipRegex.test(host) && !hostnameRegex.test(host) && host !== 'localhost') {
    showToast('Invalid host address', 'error');
    return;
  }
  
  if (port < 1025 || port > 65535) {
    showToast('Invalid port (1025-65535)', 'error');
    return;
  }
  
  // Get selected exclude folders from checkboxes
  excludeFolders = [];
  document.querySelectorAll('#excludeFolderGrid input:checked').forEach(cb => {
    excludeFolders.push(cb.value);
  });
  
  settings.host = host;
  settings.port = port;
  settings.syncInterval = parseInt(document.getElementById('syncInterval').value, 10);
  settings.defaultFolder = document.getElementById('defaultFolder').value;
  settings.apiKey = document.getElementById('apiKey').value.trim();
  
  await chrome.storage.sync.set(settings);
  await chrome.storage.local.set({ excludeFolders });
  chrome.runtime.sendMessage({ action: 'updateSettings', settings: { ...settings, excludeFolders } });
  
  showToast('Settings saved!', 'success');
  checkConnection();
});

function showToast(message, type) {
  const toast = document.getElementById('toast');
  toast.textContent = (type === 'success' ? '✓ ' : '✗ ') + message;
  toast.className = 'toast ' + type + ' show';
  setTimeout(() => toast.classList.remove('show'), 2500);
}

// Load About tab info
function loadAboutInfo() {
  const manifest = chrome.runtime.getManifest();
  document.getElementById('extVersion').textContent = manifest.version;
}

// Import browser bookmarks
document.getElementById('importBtn').addEventListener('click', async () => {
  const btn = document.getElementById('importBtn');
  const status = document.getElementById('importStatus');
  const selectFolder = document.getElementById('importFolder').value;
  const customFolder = document.getElementById('importCustomFolder').value.trim();
  const importFolder = selectFolder === '__custom__' ? customFolder : selectFolder;
  const host = document.getElementById('host').value.trim() || '127.0.0.1';
  const port = document.getElementById('port').value || 52525;
  const url = `http://${host}:${port}`;
  
  // Count bookmarks first
  const tree = await chrome.bookmarks.getTree();
  let count = 0;
  function countBookmarks(nodes) {
    for (const node of nodes) {
      if (node.url) count++;
      else if (node.children) countBookmarks(node.children);
    }
  }
  countBookmarks(tree);
  
  if (!await showConfirm('Import Bookmarks', `Import ${count} bookmarks to VaultNote?\n\nThis may take a while.`)) return;
  
  btn.disabled = true;
  btn.textContent = 'Importing...';
  status.textContent = '';
  
  try {
    const bookmarks = [];
    
    function traverse(nodes, path = '') {
      for (const node of nodes) {
        if (node.url) {
          const folder = importFolder || path || 'Bookmarks';
          bookmarks.push({ url: node.url, title: node.title, folder });
        } else if (node.children) {
          const folderPath = path ? `${path}/${node.title}` : node.title;
          traverse(node.children, folderPath);
        }
      }
    }
    traverse(tree);
    
    let existingUrls = new Set();
    try {
      const res = await fetch(`${url}/bookmarks`, { headers: getHeaders() });
      if (res.ok) existingUrls = new Set((await res.json()).map(b => b.url));
    } catch (e) {}
    
    let sent = 0, skipped = 0, failed = 0;
    for (const b of bookmarks) {
      if (existingUrls.has(b.url)) { skipped++; continue; }
      try {
        const res = await fetch(`${url}/bookmark`, {
          method: 'POST',
          headers: getHeaders(),
          body: JSON.stringify({ ...b, tags: document.getElementById('importTags').value.split(',').map(t => t.trim()).filter(t => t), source: 'import' })
        });
        if (res.ok) sent++;
        else failed++;
      } catch (e) { failed++; }
      status.textContent = `Importing... ${sent} sent, ${skipped} skipped${failed ? ', ' + failed + ' failed' : ''}`;
    }
    
    status.textContent = `Done! ${sent} imported, ${skipped} existed${failed ? ', ' + failed + ' failed' : ''}`;
    showToast(`Imported ${sent} bookmarks${failed ? ' (' + failed + ' failed)' : ''}`, failed ? 'error' : 'success');
    
    // Auto-add import folder(s) to excludeFolders (so they won't sync back to this browser)
    let foldersToExclude = [];
    if (importFolder) {
      // Specific folder selected
      foldersToExclude = [importFolder];
    } else {
      // "Keep original folders" - exclude all top-level folders that were imported
      const importedFolders = [...new Set(bookmarks.map(b => b.folder.split('/')[0]))];
      foldersToExclude = importedFolders;
    }
    
    let added = 0;
    for (const f of foldersToExclude) {
      if (f && !excludeFolders.includes(f)) {
        excludeFolders.push(f);
        added++;
      }
    }
    if (added > 0) {
      await chrome.storage.local.set({ excludeFolders });
      chrome.runtime.sendMessage({ action: 'updateSettings', settings: { ...settings, excludeFolders } });
      // Add new folders to list and refresh UI
      for (const f of foldersToExclude) {
        if (!vaultNoteFolders.includes(f)) vaultNoteFolders.push(f);
      }
      vaultNoteFolders.sort();
      renderSyncFolders();
    }
  } catch (e) {
    status.textContent = 'Failed: ' + e.message;
    showToast('Import failed', 'error');
  } finally {
    btn.disabled = false;
    btn.textContent = 'Import All Bookmarks';
  }
});
