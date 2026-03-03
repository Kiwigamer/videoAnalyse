/* ═══════════════════════════════════════════════════════════
   PiStation — Dashboard JS (HDMI-Anzeige)
   ═══════════════════════════════════════════════════════════ */

const socket = io();
let qrGenerated = false;

// ─── SocketIO ───────────────────────────────────────────────
socket.on('connect', () => {
  console.log('Dashboard: SocketIO verbunden');
});

socket.on('status_update', (status) => {
  updateDashboard(status);
});

// ─── UI-Update ──────────────────────────────────────────────
function updateDashboard(status) {
  const noVideoScreen = document.getElementById('noVideoScreen');
  const videoScreen   = document.getElementById('videoScreen');

  if (!status.playing) {
    noVideoScreen.classList.remove('hidden');
    videoScreen.classList.add('hidden');
  } else {
    noVideoScreen.classList.add('hidden');
    videoScreen.classList.remove('hidden');

    document.getElementById('filename').textContent  = status.filename || '—';
    document.getElementById('timePos').textContent   = formatTime(status.position);
    document.getElementById('timeDur').textContent   = formatTime(status.duration);
    document.getElementById('percent').textContent   = status.percent + '%';
    document.getElementById('speed').textContent     = Number(status.speed).toFixed(2);
    document.getElementById('volume').textContent    = status.volume;

    const bar = document.getElementById('progressBar');
    bar.style.width = Math.min(100, status.percent) + '%';

    const pausedBadge = document.getElementById('pausedBadge');
    if (status.paused) {
      pausedBadge.classList.remove('hidden');
    } else {
      pausedBadge.classList.add('hidden');
    }
  }

  // Server-IP anzeigen
  if (status.server_ip) {
    document.getElementById('serverIp').textContent = status.server_ip;
  }

  // AP-URL und QR-Code
  const apIp  = status.ap_ip  || '10.42.0.1';
  const apUrl = 'http://' + apIp;
  document.getElementById('apUrl').textContent = apUrl;

  if (!qrGenerated) {
    generateQRCode(apUrl);
    qrGenerated = true;
  }
}

// ─── QR-Code ─────────────────────────────────────────────────
function generateQRCode(url) {
  const container = document.getElementById('qrcode');
  container.innerHTML = '';
  try {
    new QRCode(container, {
      text:          url,
      width:         96,
      height:        96,
      colorDark:     '#f0f0f0',
      colorLight:    '#0d0d0d',
      correctLevel:  QRCode.CorrectLevel.M,
    });
  } catch (e) {
    console.warn('QR-Code konnte nicht generiert werden:', e);
    container.textContent = url;
  }
}

// ─── Zeitformatierung ────────────────────────────────────────
function formatTime(seconds) {
  if (!seconds || isNaN(seconds) || seconds < 0) return '00:00';
  const s = Math.floor(seconds);
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  const sec = s % 60;
  const pad = (n) => String(n).padStart(2, '0');
  if (h > 0) return `${pad(h)}:${pad(m)}:${pad(sec)}`;
  return `${pad(m)}:${pad(sec)}`;
}

// ─── Fallback: IP alle 5s aus /api/info laden ─────────────────
async function fetchInfo() {
  try {
    const res  = await fetch('/api/info');
    const data = await res.json();
    if (data.server_ip) {
      document.getElementById('serverIp').textContent = data.server_ip;
    }
    const apUrl = 'http://' + (data.ap_ip || '10.42.0.1');
    document.getElementById('apUrl').textContent = apUrl;
    if (!qrGenerated) {
      generateQRCode(apUrl);
      qrGenerated = true;
    }
  } catch (e) {
    // ignorieren
  }
}

fetchInfo();
setInterval(fetchInfo, 5000);
