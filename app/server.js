const express = require('express');
const { WebSocketServer } = require('ws');
const pty = require('node-pty');
const { v4: uuidv4 } = require('uuid');
const fs = require('fs');
const path = require('path');
const http = require('http');
const { execSync, spawnSync, exec } = require('child_process');
const { promisify } = require('util');
const execAsync = (cmd, opts = {}) => promisify(exec)(cmd, { timeout: 120000, ...opts });

const app = express();
const server = http.createServer(app);
const wss = new WebSocketServer({ server });

const DATA_FILE = path.join(__dirname, 'data.json');
const CONTAINER_COUNT = Number.parseInt(process.env.CONTAINER_COUNT || '10', 10);
const CONTAINER_IP_OFFSET = Number.parseInt(process.env.CONTAINER_IP_OFFSET || '10', 10);
const CONTAINER_IP_PREFIX = process.env.CONTAINER_IP_PREFIX || '10.10.0';
const CONTAINER_MEMORY = process.env.CONTAINER_MEMORY || '1536MB';
const CONTAINER_SWAP = process.env.CONTAINER_SWAP || 'true';
const CONTAINER_EXTRA_PACKAGES = process.env.CONTAINER_EXTRA_PACKAGES || '';
const CONTAINER_SSH_ENABLED = process.env.CONTAINER_SSH_ENABLED || '0';
const CONTAINER_RUNTIME = process.env.CONTAINER_RUNTIME || 'lxd';
const LXC_BIN = process.env.RUNTIME_CLIENT || 'lxc';
const CONTAINER_IMAGE = process.env.CONTAINER_IMAGE || 'ubuntu:24.04';
const LXD_BRIDGE_NAME = process.env.LXD_BRIDGE_NAME || 'lxdbr0';
const STORAGE_CONTAINERS_PATH = process.env.STORAGE_CONTAINERS_PATH || '';
const LXD_BRIDGE_IP = process.env.LXD_BRIDGE_IP || '10.10.0.1';
const BIND_ADDRESS = process.env.BIND_ADDRESS || '127.0.0.1';

if (!Number.isInteger(CONTAINER_COUNT) || CONTAINER_COUNT < 1 || CONTAINER_COUNT > 100) {
  throw new Error('CONTAINER_COUNT must be an integer between 1 and 100');
}

if (!Number.isInteger(CONTAINER_IP_OFFSET) || CONTAINER_IP_OFFSET < 2 || CONTAINER_IP_OFFSET > 254) {
  throw new Error('CONTAINER_IP_OFFSET must be an integer between 2 and 254');
}

if (CONTAINER_IP_OFFSET + CONTAINER_COUNT - 1 > 254) {
  throw new Error('CONTAINER_IP_OFFSET + CONTAINER_COUNT - 1 must be <= 254');
}

function containerIds() {
  return Array.from({ length: CONTAINER_COUNT }, (_, i) => String(i));
}

function isValidContainerId(value) {
  if (!/^\d+$/.test(String(value))) return false;
  const numericId = Number.parseInt(String(value), 10);
  return numericId >= 0 && numericId < CONTAINER_COUNT;
}

function requireValidContainerId(value, errorMessage) {
  const cid = String(value);
  if (!isValidContainerId(cid)) {
    const error = new Error(errorMessage);
    error.status = 400;
    throw error;
  }
  return cid;
}

function containerIp(containerId) {
  return `${CONTAINER_IP_PREFIX}.${CONTAINER_IP_OFFSET + Number.parseInt(containerId, 10)}`;
}

function formatBytes(bytes) {
  if (!Number.isFinite(bytes) || bytes < 0) return '-';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  let value = bytes;
  let unitIndex = 0;
  while (value >= 1024 && unitIndex < units.length - 1) {
    value /= 1024;
    unitIndex += 1;
  }
  const digits = value >= 10 || unitIndex === 0 ? 0 : 1;
  return `${value.toFixed(digits)} ${units[unitIndex]}`;
}

function getHostDiskSummary() {
  try {
    const out = execSync('df -B1 --output=size,avail,pcent / | tail -n 1', {
      encoding: 'utf8',
      timeout: 3000,
    }).trim();
    const [sizeRaw, availRaw, usedPercent = '-'] = out.split(/\s+/);
    const totalBytes = Number.parseInt(sizeRaw, 10);
    const availableBytes = Number.parseInt(availRaw, 10);
    return {
      total: formatBytes(totalBytes),
      available: formatBytes(availableBytes),
      usedPercent,
    };
  } catch (_) {
    return { total: '-', available: '-', usedPercent: '-' };
  }
}

function loadData() {
  if (!fs.existsSync(DATA_FILE)) {
    const init = { teacherPassword: 'admin', nicknames: {} };
    fs.writeFileSync(DATA_FILE, JSON.stringify(init, null, 2));
    return init;
  }
  const data = JSON.parse(fs.readFileSync(DATA_FILE, 'utf8'));
  if (!data.nicknames) data.nicknames = {};
  if (!data.externalIps) data.externalIps = {};
  return data;
}

// 컨테이너 Linux 계정 비밀번호를 /etc/shadow와 대조
function verifyContainerPassword(containerId, password) {
  const script = `
import crypt, sys
pw = sys.stdin.read().strip()
for line in open('/etc/shadow'):
    if line.startswith('server:'):
        h = line.split(':')[1]
        sys.exit(0 if crypt.crypt(pw, h) == h else 1)
sys.exit(1)
`;
  const result = spawnSync(LXC_BIN, ['exec', `server${containerId}`, '--', 'python3', '-c', script], {
    input: password,
    encoding: 'utf8',
    timeout: 5000
  });
  return result.status === 0;
}

function saveData(data) {
  fs.writeFileSync(DATA_FILE, JSON.stringify(data, null, 2));
}

// 세션 저장소 (메모리)
const studentSessions = new Map(); // token -> containerId
const adminSessions = new Set();   // token

app.use(express.json());
app.use(express.static(path.join(__dirname, 'public')));

// ── 학생 인증 ──────────────────────────────────────────────
app.post('/api/auth', (req, res) => {
  const { id, password } = req.body;
  let cid;
  try {
    cid = requireValidContainerId(id, '잘못된 컨테이너 번호');
  } catch (error) {
    return res.status(error.status || 400).json({ error: error.message });
  }
  if (resetStatus.get(cid) === 'resetting') {
    return res.status(423).json({ error: '컨테이너 초기화 진행 중입니다. 잠시 후 다시 시도하세요.' });
  }
  if (!password) return res.status(400).json({ error: '비밀번호를 입력하세요' });
  if (!verifyContainerPassword(cid, password)) return res.status(401).json({ error: '비밀번호가 틀렸습니다' });
  const token = uuidv4();
  studentSessions.set(token, cid);
  res.json({ token, id: cid });
});

// ── 관리자 인증 ────────────────────────────────────────────
app.post('/api/admin/login', (req, res) => {
  const { password } = req.body;
  const data = loadData();
  if (data.teacherPassword !== password) return res.status(401).json({ error: '비밀번호가 틀렸습니다' });
  const token = uuidv4();
  adminSessions.add(token);
  res.json({ token });
});

function requireAdmin(req, res, next) {
  const auth = req.headers.authorization || '';
  const token = auth.replace('Bearer ', '');
  if (!adminSessions.has(token)) return res.status(401).json({ error: '인증 필요' });
  next();
}

function requireStudent(req, res, next) {
  const auth = req.headers.authorization || '';
  const token = auth.replace('Bearer ', '');
  const containerId = studentSessions.get(token);
  if (!containerId) return res.status(401).json({ error: '인증 필요' });
  req.studentToken = token;
  req.studentContainerId = containerId;
  next();
}

// ── 공개 API (학생용) ──────────────────────────────────────
app.get('/api/containers', (req, res) => {
  const data = loadData();
  const result = containerIds().map(cid => ({
    id: cid,
    nickname: data.nicknames[cid] || '',
    externalIp: data.externalIps[cid] || '',
    isResetting: resetStatus.get(cid) === 'resetting'
  }));
  res.json(result);
});

// ── 관리자 API ─────────────────────────────────────────────
app.get('/api/admin/containers', requireAdmin, (req, res) => {
  const data = loadData();
  // lxc list를 한 번만 호출해서 전체 상태 파싱
  let stateMap = {};
  let usageMap = {};
  try {
    const out = execSync(`${LXC_BIN} list "^server[0-9]+$" --format=csv -c n,s`, { encoding: 'utf8' });
    out.trim().split('\n').filter(Boolean).forEach(line => {
      const [name, state] = line.split(',');
      const id = name.replace('server', '');
      if (!isValidContainerId(id)) return;
      const normalizedState = state.toLowerCase();
      stateMap[id] = normalizedState;
      usageMap[id] = '-';
      if (normalizedState !== 'running') return;
      try {
        const stateJson = execSync(`${LXC_BIN} query /1.0/instances/server${id}/state`, {
          encoding: 'utf8',
          timeout: 5000,
        });
        const state = JSON.parse(stateJson);
        const usageBytes = state?.disk?.root?.usage;
        if (Number.isFinite(usageBytes)) {
          usageMap[id] = formatBytes(usageBytes);
        }
      } catch (_) {}
    });
  } catch (_) {}
  const result = containerIds().map(cid => ({
    id: cid,
    nickname: data.nicknames[cid] || '',
    externalIp: data.externalIps[cid] || '',
    state: stateMap[cid] || 'stopped',
    diskUsage: usageMap[cid] || '-'
  }));
  res.json(result);
});

app.get('/api/admin/disk-summary', requireAdmin, (req, res) => {
  res.json(getHostDiskSummary());
});

app.put('/api/admin/nickname/:id', requireAdmin, (req, res) => {
  const data = loadData();
  let cid;
  try {
    cid = requireValidContainerId(req.params.id, '잘못된 ID');
  } catch (error) {
    return res.status(error.status || 400).json({ error: error.message });
  }
  data.nicknames[cid] = req.body.nickname || '';
  saveData(data);
  res.json({ ok: true });
});

app.put('/api/admin/externalip/:id', requireAdmin, (req, res) => {
  const data = loadData();
  let cid;
  try {
    cid = requireValidContainerId(req.params.id, '잘못된 ID');
  } catch (error) {
    return res.status(error.status || 400).json({ error: error.message });
  }
  data.externalIps[cid] = req.body.externalIp || '';
  saveData(data);
  res.json({ ok: true });
});

app.put('/api/admin/teacher-password', requireAdmin, (req, res) => {
  const { currentPassword, newPassword } = req.body;
  const data = loadData();
  if (data.teacherPassword !== currentPassword) return res.status(401).json({ error: '현재 비밀번호가 틀렸습니다' });
  data.teacherPassword = newPassword;
  saveData(data);
  res.json({ ok: true });
});

// ── 초기화 큐 ─────────────────────────────────────────────
const resetStatus = new Map(); // cid -> 'pending' | 'resetting' | 'done' | 'error'
const resetQueue = [];         // [{cid, clearNickname}] 순서대로 대기
let resetQueueRunning = false;

// Values passed to create-containers.sh on reset. Passed as a child-process
// env object (not a shell string) so values with spaces/quotes are safe.
const RESET_SCRIPT_VALUES = () => ({
  CONTAINER_RUNTIME,
  RUNTIME_CLIENT: LXC_BIN,
  CONTAINER_COUNT: String(CONTAINER_COUNT),
  CONTAINER_IP_OFFSET: String(CONTAINER_IP_OFFSET),
  CONTAINER_IP_PREFIX,
  CONTAINER_MEMORY,
  CONTAINER_SWAP,
  CONTAINER_EXTRA_PACKAGES,
  CONTAINER_SSH_ENABLED,
  CONTAINER_IMAGE,
  LXD_BRIDGE_NAME,
  LXD_BRIDGE_IP,
  STORAGE_CONTAINERS_PATH,
});

async function processResetQueue() {
  if (resetQueueRunning) return;
  resetQueueRunning = true;
  while (resetQueue.length > 0) {
    const { cid, clearNickname } = resetQueue[0];
    resetStatus.set(cid, 'resetting');
    const scriptPath = path.join(__dirname, 'scripts', 'create-containers.sh');
    let succeeded = false;
    for (let attempt = 1; attempt <= 3; attempt++) {
      try {
        await execAsync(`bash "${scriptPath}" ${cid}`, {
          timeout: 300000,
          env: { ...process.env, ...RESET_SCRIPT_VALUES() },
        });
        succeeded = true;
        break;
      } catch (e) {
        console.error(`server${cid} 초기화 실패 (${attempt}/3):`, e.message);
      }
    }
    if (succeeded) {
      if (clearNickname) {
        const data = loadData();
        data.nicknames[cid] = '';
        saveData(data);
      }
      resetStatus.set(cid, 'done');
      console.log(`server${cid} 초기화 완료`);
    } else {
      resetStatus.set(cid, 'error');
    }
    resetQueue.shift();
  }
  resetQueueRunning = false;
}

function enqueueReset(cid, clearNickname) {
  const s = resetStatus.get(cid);
  if (s === 'pending' || s === 'resetting') return false;
  resetQueue.push({ cid, clearNickname });
  resetStatus.set(cid, 'pending');
  processResetQueue();
  return true;
}

function resetQueueInfo() {
  const queueCids = resetQueue.map(item => item.cid);
  return { queue: queueCids, total: queueCids.length };
}

app.get('/api/admin/reset-status', requireAdmin, (req, res) => {
  const status = {};
  resetStatus.forEach((v, k) => { status[k] = v; });
  res.json({ status, ...resetQueueInfo() });
});

app.post('/api/admin/reset', requireAdmin, (req, res) => {
  const { ids, clearNickname } = req.body;
  if (!Array.isArray(ids) || ids.length === 0) return res.status(400).json({ error: 'ids 필요' });
  let normalizedIds;
  try {
    normalizedIds = [...new Set(ids.map(id => requireValidContainerId(id, '잘못된 ID')))];
  } catch (error) {
    return res.status(error.status || 400).json({ error: error.message });
  }
  const queued = normalizedIds.filter(id => enqueueReset(id, clearNickname)).length;
  res.json({ ok: true, message: `${queued}개 컨테이너 초기화 대기열에 추가됨` });
});

app.post('/api/reset-self', requireStudent, (req, res) => {
  const cid = req.studentContainerId;
  const queued = enqueueReset(cid, false);
  if (!queued) return res.status(409).json({ error: '이미 초기화 대기 또는 진행 중입니다.' });
  studentSessions.delete(req.studentToken);
  const pos = resetQueue.findIndex(item => item.cid === cid) + 1;
  res.json({ ok: true, message: `server${cid} 초기화 대기열 등록 (${pos}번째)` });
});

// ── WebSocket 터미널 ───────────────────────────────────────
wss.on('connection', (ws, req) => {
  const url = new URL(req.url, 'http://localhost');
  const token = url.searchParams.get('token');
  const type = url.searchParams.get('type'); // 'student' | 'admin-preview'
  const id = url.searchParams.get('id');

  let containerId;

  if (type === 'admin') {
    // 교사가 특정 컨테이너 미리보기
    if (!adminSessions.has(token)) return ws.close(1008, 'Unauthorized');
    if (!isValidContainerId(id)) return ws.close(1008, 'Unauthorized');
    containerId = String(id);
  } else {
    // 학생
    if (!studentSessions.has(token)) return ws.close(1008, 'Unauthorized');
    containerId = studentSessions.get(token);
  }

  let ptyProcess;
  try {
    ptyProcess = pty.spawn(LXC_BIN, ['exec', `server${containerId}`, '--', 'su', '-', 'server'], {
      name: 'xterm-256color',
      cols: 80,
      rows: 24,
      env: process.env
    });
  } catch (e) {
    ws.send('\r\n컨테이너에 연결할 수 없습니다.\r\n');
    ws.close();
    return;
  }

  ptyProcess.onData(data => {
    if (ws.readyState === ws.OPEN) ws.send(data);
  });

  ptyProcess.onExit(() => {
    if (ws.readyState === ws.OPEN) ws.close();
  });

  ws.on('message', msg => {
    try {
      const data = JSON.parse(msg);
      if (data.type === 'resize') {
        ptyProcess.resize(data.cols, data.rows);
      } else if (data.type === 'input') {
        ptyProcess.write(data.data);
      }
    } catch (_) {
      ptyProcess.write(msg);
    }
  });

  ws.on('close', () => {
    try { ptyProcess.kill(); } catch (_) {}
  });
});

const PORT = 3000;
server.listen(PORT, BIND_ADDRESS, () => {
  console.log(`LXD Classroom running on http://${BIND_ADDRESS}:${PORT}`);
});
