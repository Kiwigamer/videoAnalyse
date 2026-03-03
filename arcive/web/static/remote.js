/* ═══════════════════════════════════════════════════════════
   PiStation — Remote JS (Handy-Fernbedienung)
   ═══════════════════════════════════════════════════════════ */

const socket    = io();
let currentStatus = {};
let isSeeking   = false;
let volumeSending = false;

// ─── SocketIO ───────────────────────────────────────────────
socket.on('connect', () => {
  console.log('Remote: SocketIO verbunden');
  loadVideoList();
});

socket.on('status_update', (status) => {
  currentStatus = status;
  if (!isSeeking) updateRemote(status);
});

// ─── Tab Navigation ──────────────────────────────────────────
document.querySelectorAll('.tab-btn').forEach((btn) => {
  btn.addEventListener('click', () => {
    const tab = btn.dataset.tab;
    document.querySelectorAll('.tab-btn').forEach((b) => b.classList.remove('active'));
    document.querySelectorAll('.tab-content').forEach((c) => c.classList.remove('active'));
    btn.classList.add('active');
    document.getElementById('tab-' + tab).classList.add('active');

    if (tab === 'videos') loadVideoList();
  });
});

// ─── UI-Update ───────────────────────────────────────────────
function updateRemote(status) {
  // Dateiname und Zeitanzeige
  document.getElementById('r-filename').textContent =
    status.playing ? (status.filename || 'Unbekannt') : 'Kein Video';

  document.getElementById('r-time').textContent =
    status.playing
      ? formatTime(status.position) + ' / ' + formatTime(status.duration)
      : '—';

  document.getElementById('r-pos').textContent     = formatTime(status.position);
  document.getElementById('r-dur').textContent     = formatTime(status.duration);
  document.getElementById('r-percent').textContent = (status.percent || 0) + '%';

  // Seek Slider
  const seekSlider = document.getElementById('seekSlider');
  seekSlider.max   = status.duration || 100;
  seekSlider.value = status.position || 0;

  // Play/Pause Button
  const ppBtn = document.getElementById('playPauseBtn');
  if (status.paused || !status.playing) {
    ppBtn.textContent = '▶ Play';
  } else {
    ppBtn.textContent = '⏸ Pause';
  }

  // Volume Slider (nur wenn nicht gerade gezogen wird)
  if (!volumeSending) {
    const vSlider = document.getElementById('volumeSlider');
    vSlider.value = status.volume || 100;
    document.getElementById('volumeDisplay').textContent = status.volume || 100;
  }

  // Geschwindigkeit markieren
  highlightSpeed(status.speed || 1.0);
}

function highlightSpeed(speed) {
  document.querySelectorAll('.speed-btn').forEach((btn) => {
    btn.classList.remove('active-speed');
  });

  const map = { 0.25: '0.25', 0.5: '0.5', 1.0: '1', 1.5: '1.5', 2.0: '2' };
  const label = map[speed];
  if (label) {
    document.querySelectorAll('.speed-btn').forEach((btn) => {
      if (btn.textContent.trim().replace('x', '') === label) {
        btn.classList.add('active-speed');
      }
    });
  }
}

// ─── API: Control ────────────────────────────────────────────
async function sendControl(action, value = null) {
  const body = { action };
  if (value !== null) body.value = value;
  try {
    await fetch('/api/control', {
      method:  'POST',
      headers: { 'Content-Type': 'application/json' },
      body:    JSON.stringify(body),
    });
  } catch (e) {
    console.error('Fehler bei sendControl:', e);
  }
}

// ─── Seek Slider ─────────────────────────────────────────────
const seekSlider = document.getElementById('seekSlider');

seekSlider.addEventListener('input', () => {
  isSeeking = true;
  document.getElementById('r-pos').textContent = formatTime(parseFloat(seekSlider.value));
});

seekSlider.addEventListener('change', () => {
  isSeeking = false;
  sendControl('seek_absolute', parseFloat(seekSlider.value));
});

// ─── Volume Slider ───────────────────────────────────────────
const volumeSlider = document.getElementById('volumeSlider');

volumeSlider.addEventListener('input', () => {
  volumeSending = true;
  document.getElementById('volumeDisplay').textContent = volumeSlider.value;
});

volumeSlider.addEventListener('change', () => {
  sendControl('set_volume', parseInt(volumeSlider.value));
  setTimeout(() => { volumeSending = false; }, 1000);
});

// ─── API: Video abspielen ─────────────────────────────────────
async function playVideo(filename) {
  try {
    await fetch('/api/play', {
      method:  'POST',
      headers: { 'Content-Type': 'application/json' },
      body:    JSON.stringify({ file: filename }),
    });
  } catch (e) {
    console.error('Fehler bei playVideo:', e);
  }
}

// ─── API: Video löschen ───────────────────────────────────────
async function deleteVideo(filename) {
  if (!confirm(`"${filename}" wirklich löschen?`)) return;
  try {
    await fetch('/api/videos/' + encodeURIComponent(filename), { method: 'DELETE' });
    loadVideoList();
  } catch (e) {
    console.error('Fehler bei deleteVideo:', e);
  }
}

// ─── API: Video-Liste laden ───────────────────────────────────
async function loadVideoList() {
  const container = document.getElementById('videoList');
  container.innerHTML = '<div class="loading">Lade…</div>';
  try {
    const res    = await fetch('/api/videos');
    const videos = await res.json();
    renderVideoList(videos);
  } catch (e) {
    container.innerHTML = '<div class="loading">Fehler beim Laden der Liste.</div>';
  }
}

function renderVideoList(videos) {
  const container = document.getElementById('videoList');
  if (!videos || videos.length === 0) {
    container.innerHTML = '<div class="loading">Keine Videos vorhanden.</div>';
    return;
  }

  container.innerHTML = videos.map((v) => `
    <div class="video-item">
      <span class="video-item-name">🎬 ${escapeHtml(v)}</span>
      <button class="video-item-btn" onclick="playVideo(${JSON.stringify(v)})" title="Abspielen">▶</button>
      <button class="video-item-btn delete" onclick="deleteVideo(${JSON.stringify(v)})" title="Löschen">🗑</button>
    </div>
  `).join('');
}

// ─── Upload mit Fortschritt ───────────────────────────────────
document.getElementById('fileInput').addEventListener('change', (e) => {
  const file = e.target.files[0];
  if (!file) return;
  uploadFile(file);
  e.target.value = ''; // Reset damit gleiche Datei nochmal gewählt werden kann
});

function uploadFile(file) {
  const progressEl = document.getElementById('uploadProgress');
  const barEl      = document.getElementById('uploadBar');
  const pctEl      = document.getElementById('uploadPercent');
  const statusEl   = document.getElementById('uploadStatus');

  progressEl.classList.remove('hidden');
  barEl.style.width  = '0%';
  pctEl.textContent  = '0%';
  statusEl.textContent = '';

  const formData = new FormData();
  formData.append('video', file);

  const xhr = new XMLHttpRequest();

  xhr.upload.addEventListener('progress', (e) => {
    if (e.lengthComputable) {
      const pct = Math.round((e.loaded / e.total) * 100);
      barEl.style.width = pct + '%';
      pctEl.textContent = pct + '%';
    }
  });

  xhr.addEventListener('load', () => {
    progressEl.classList.add('hidden');
    if (xhr.status === 200) {
      statusEl.textContent = '✅ Upload erfolgreich!';
      loadVideoList();
    } else {
      statusEl.textContent = '❌ Upload fehlgeschlagen.';
    }
    setTimeout(() => { statusEl.textContent = ''; }, 4000);
  });

  xhr.addEventListener('error', () => {
    progressEl.classList.add('hidden');
    statusEl.textContent = '❌ Netzwerkfehler beim Upload.';
  });

  xhr.open('POST', '/api/upload');
  xhr.send(formData);
}

// ─── Hilfsfunktionen ─────────────────────────────────────────
function formatTime(seconds) {
  if (!seconds || isNaN(seconds) || seconds < 0) return '00:00';
  const s   = Math.floor(seconds);
  const h   = Math.floor(s / 3600);
  const m   = Math.floor((s % 3600) / 60);
  const sec = s % 60;
  const pad = (n) => String(n).padStart(2, '0');
  if (h > 0) return `${pad(h)}:${pad(m)}:${pad(sec)}`;
  return `${pad(m)}:${pad(sec)}`;
}

function escapeHtml(str) {
  return str
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}
