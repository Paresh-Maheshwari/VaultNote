// ============================================================================
// VAULTNOTE BOOKMARK SYNC - POPUP SCRIPT
// ============================================================================
//
// Extension popup interface for manual bookmark management:
// - Save current page to VaultNote
// - Select folder for organization
// - Check connection status with VaultNote app
// - Manual sync trigger
// - Quick access to settings
//
// Features:
// - Real-time connection status indicator
// - Folder selection dropdown
// - One-click bookmark saving
// - Sync status and progress
// - Error handling and user feedback
//
// ============================================================================

// VaultNote Bookmark Sync - Popup Script

let FLUTTER_APP_URL = 'http://127.0.0.1:52525';
let API_KEY = '';
let settings = {};

// Get headers with optional API key
function getHeaders() {
  const headers = { 'Content-Type': 'application/json' };
  if (API_KEY) headers['X-API-Key'] = API_KEY;
  return headers;
}

// DOM elements
const statusDot = document.getElementById('statusDot');
const statusText = document.getElementById('statusText');
const folderSelect = document.getElementById('folder');
const saveBtn = document.getElementById('saveBtn');
const syncBtn = document.getElementById('syncBtn');
const syncInfo = document.getElementById('syncInfo');
const toast = document.getElementById('toast');

// Initialize popup
document.addEventListener('DOMContentLoaded', async () => {
  // Load settings
  settings = await chrome.storage.sync.get({
    host: '127.0.0.1',
    port: 52525,
    syncInterval: 30,
    defaultFolder: 'Browser Sync',
    folders: ['Browser Sync', 'Work', 'Personal', 'Research', 'Reading List'],
    apiKey: '',
    darkMode: false
  });
  
  FLUTTER_APP_URL = `http://${settings.host}:${settings.port}`;
  API_KEY = settings.apiKey || '';
  
  // Apply dark mode
  if (settings.darkMode) {
    document.body.classList.add('dark');
  }
  
  // Populate folders
  folderSelect.innerHTML = settings.folders.map(f => 
    `<option value="${f}" ${f === settings.defaultFolder ? 'selected' : ''}>📁 ${f}</option>`
  ).join('');
  
  // Update sync info
  if (settings.syncInterval > 0) {
    const label = settings.syncInterval >= 60 
      ? `${settings.syncInterval / 60}m` 
      : `${settings.syncInterval}s`;
    syncInfo.textContent = `Auto-sync: ${label}`;
  } else {
    syncInfo.textContent = 'Auto-sync: Off';
  }
  
  await checkConnection();
  setupEventListeners();
});

async function checkConnection() {
  try {
    const controller = new AbortController();
    const timeoutId = setTimeout(() => controller.abort(), 2000);
    const response = await fetch(`${FLUTTER_APP_URL}/ping`, { 
      signal: controller.signal,
      headers: getHeaders()
    });
    clearTimeout(timeoutId);
    setConnected(response.ok);
  } catch (error) {
    setConnected(false);
  }
}

function setConnected(connected) {
  statusDot.classList.toggle('connected', connected);
  statusText.textContent = connected ? 'Connected to VaultNote' : 'VaultNote offline (will queue)';
  syncBtn.disabled = !connected;
  // Save button always enabled - will queue if offline
}

function setupEventListeners() {
  saveBtn.addEventListener('click', saveCurrentPage);
  syncBtn.addEventListener('click', syncNow);
  document.getElementById('settingsLink').addEventListener('click', (e) => {
    e.preventDefault();
    chrome.tabs.create({ url: chrome.runtime.getURL('settings.html') });
  });
  
  // Theme toggle
  document.getElementById('themeBtn').addEventListener('click', async () => {
    settings.darkMode = !settings.darkMode;
    document.body.classList.toggle('dark', settings.darkMode);
    await chrome.storage.sync.set({ darkMode: settings.darkMode });
  });
}

async function saveCurrentPage() {
  try {
    const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
    const folder = folderSelect.value;
    const tagsInput = document.getElementById('tags').value;
    const tags = tagsInput.split(',').map(t => t.trim()).filter(t => t);
    
    saveBtn.disabled = true;
    
    const bookmark = {
      title: tab.title,
      url: tab.url,
      folder: folder,
      tags: tags.length ? tags : ['browser-sync'],
      description: '',
      source: 'popup'
    };
    
    try {
      const controller = new AbortController();
      const timeoutId = setTimeout(() => controller.abort(), 3000);
      
      const response = await fetch(`${FLUTTER_APP_URL}/bookmark`, {
        method: 'POST',
        headers: getHeaders(),
        body: JSON.stringify(bookmark),
        signal: controller.signal
      });
      
      clearTimeout(timeoutId);
      
      if (response.ok) {
        showToast('Bookmark saved!', 'success');
        setTimeout(() => window.close(), 1000);
        return;
      }
      throw new Error('Server error');
    } catch (e) {
      // Offline - save directly to storage (don't rely on service worker)
      const { offlineQueue = [] } = await chrome.storage.local.get('offlineQueue');
      if (!offlineQueue.some(b => b.url === bookmark.url) || bookmark.description) {
        offlineQueue.push(bookmark);
        await chrome.storage.local.set({ offlineQueue });
      }
      showToast('Queued for sync', 'success');
      setTimeout(() => window.close(), 1000);
    }
  } catch (error) {
    showToast('Error: ' + error.message, 'error');
    saveBtn.disabled = false;
  }
}

async function syncNow() {
  try {
    syncBtn.disabled = true;
    syncBtn.textContent = 'Syncing...';
    
    // Trigger background sync to add VaultNote bookmarks to browser
    await chrome.runtime.sendMessage({ action: 'syncNow' });
    
    const response = await fetch(`${FLUTTER_APP_URL}/bookmarks`, { headers: getHeaders() });
    if (response.ok) {
      const bookmarks = await response.json();
      showToast(`Synced ${bookmarks.length} bookmarks`, 'success');
    } else {
      showToast('Sync failed', 'error');
    }
  } catch (error) {
    showToast('Sync error', 'error');
  } finally {
    syncBtn.disabled = false;
    syncBtn.textContent = '🔄 Sync Now';
  }
}

function showToast(message, type) {
  toast.textContent = message;
  toast.className = 'toast ' + type + ' show';
  setTimeout(() => toast.classList.remove('show'), 2500);
}

// Check connection periodically (only while popup is visible)
const connectionInterval = setInterval(checkConnection, 5000);
document.addEventListener('visibilitychange', () => {
  if (document.hidden) clearInterval(connectionInterval);
});
