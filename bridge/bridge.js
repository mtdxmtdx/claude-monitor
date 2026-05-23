/**
 * Claude Code Bridge
 * 将 Claude Code CLI 通过 WebSocket 暴露给 Android 客户端
 * 依赖: npm install ws node-pty
 */

const pty  = require('node-pty');
const ws   = require('ws');
const os   = require('os');
const fs   = require('fs');
const path = require('path');

// ──────────────────────────────────────────────
// 配置
// ──────────────────────────────────────────────
const PORT       = 8765;
const BUF_MAX    = 60_000;   // 历史缓冲上限（字节）
const BUF_KEEP   = 36_000;   // 超限后保留的尾部大小

// 目录搜索参数
const SEARCH_MAX_DEPTH   = 4;
const SEARCH_MAX_RESULTS = 200;
const SEARCH_SKIP = new Set([
  'node_modules', '.git', '.svn', '.hg', '.idea', '.vscode',
  'AppData', '$RECYCLE.BIN', 'System Volume Information',
  'Windows', 'Program Files', 'Program Files (x86)', 'ProgramData',
  '.gradle', '.dart_tool', 'build', 'dist', '.next', '.cache',
]);

// 自定义根目录持久化
const ROOTS_FILE = path.join(__dirname, 'roots.json');

// ──────────────────────────────────────────────
// 状态
// ──────────────────────────────────────────────
let shell      = null;   // 当前 PTY 进程
let scrollback = '';     // 历史缓冲（供断线重连回放）

// ──────────────────────────────────────────────
// 启动提示：打印本机所有 IP
// ──────────────────────────────────────────────
function printAddresses() {
  console.log('\n╔══════════════════════════════╗');
  console.log('║   Claude Code Bridge 已启动   ║');
  console.log('╠══════════════════════════════╣');
  const ifaces = os.networkInterfaces();
  Object.values(ifaces).flat().forEach(i => {
    if (i.family === 'IPv4' && !i.internal) {
      const tag = i.address.startsWith('100.') ? '(Tailscale)' : '(局域网)   ';
      console.log(`║  ${tag}  ${i.address.padEnd(15)} ║`);
    }
  });
  console.log(`║  端口: ${String(PORT).padEnd(22)} ║`);
  console.log('╚══════════════════════════════╝\n');
}

// ──────────────────────────────────────────────
// 目录跳转：根目录管理
// ──────────────────────────────────────────────
function defaultRoots() {
  const home = process.env.USERPROFILE || process.env.HOME || '';
  const list = [];
  const push = (label, p) => {
    if (p && fs.existsSync(p)) list.push({ label, path: p, builtin: true });
  };
  push('主目录',  home);
  push('桌面',    path.join(home, 'Desktop'));
  push('文档',    path.join(home, 'Documents'));
  push('下载',    path.join(home, 'Downloads'));
  // Windows 盘符
  if (process.platform === 'win32') {
    for (const letter of 'CDEFGHIJ') {
      const drv = `${letter}:\\`;
      try { if (fs.existsSync(drv)) push(`${letter} 盘`, drv); } catch (_) {}
    }
  }
  return list;
}

function loadCustomRoots() {
  try {
    const raw = fs.readFileSync(ROOTS_FILE, 'utf8');
    const arr = JSON.parse(raw);
    return Array.isArray(arr) ? arr.filter(r => r && r.path) : [];
  } catch (_) {
    return [];
  }
}

function saveCustomRoots(list) {
  try {
    fs.writeFileSync(ROOTS_FILE, JSON.stringify(list, null, 2), 'utf8');
    return true;
  } catch (e) {
    console.error('[bridge] 保存自定义根目录失败:', e.message);
    return false;
  }
}

function listRoots() {
  const custom = loadCustomRoots().map(r => ({ ...r, builtin: false }));
  return [...defaultRoots(), ...custom];
}

function addCustomRoot(label, p) {
  if (!p || !fs.existsSync(p)) return { ok: false, error: '路径不存在' };
  const stat = fs.statSync(p);
  if (!stat.isDirectory()) return { ok: false, error: '不是文件夹' };
  const list = loadCustomRoots();
  const norm = path.resolve(p);
  if (list.some(r => path.resolve(r.path) === norm)) {
    return { ok: false, error: '已存在' };
  }
  list.push({ label: label || path.basename(norm) || norm, path: norm });
  return saveCustomRoots(list) ? { ok: true } : { ok: false, error: '写入失败' };
}

function removeCustomRoot(p) {
  const norm = path.resolve(p);
  const list = loadCustomRoots().filter(r => path.resolve(r.path) !== norm);
  return saveCustomRoots(list);
}

// ──────────────────────────────────────────────
// 目录跳转：按关键字搜索文件夹名
// 在 root 下做受限 BFS，仅匹配文件夹名 contains keyword（不区分大小写）
// ──────────────────────────────────────────────
function searchDirs(root, keyword) {
  const results = [];
  if (!root || !fs.existsSync(root)) return results;
  const kw = (keyword || '').trim().toLowerCase();
  if (!kw) return results;

  const queue = [{ dir: root, depth: 0 }];
  while (queue.length && results.length < SEARCH_MAX_RESULTS) {
    const { dir, depth } = queue.shift();
    let entries;
    try {
      entries = fs.readdirSync(dir, { withFileTypes: true });
    } catch (_) {
      continue;
    }
    for (const ent of entries) {
      if (!ent.isDirectory()) continue;
      const name = ent.name;
      if (name.startsWith('.')) continue;
      if (SEARCH_SKIP.has(name)) continue;
      const full = path.join(dir, name);
      if (name.toLowerCase().includes(kw)) {
        results.push({ name, path: full });
        if (results.length >= SEARCH_MAX_RESULTS) break;
      }
      if (depth + 1 < SEARCH_MAX_DEPTH) {
        queue.push({ dir: full, depth: depth + 1 });
      }
    }
  }
  return results;
}

// ──────────────────────────────────────────────
// PTY 管理
// ──────────────────────────────────────────────
function spawnShell() {
  const proc = pty.spawn('cmd.exe', ['/k', 'claude'], {
    name: 'xterm-256color',
    cols: 80,
    rows: 24,
    cwd:  process.env.USERPROFILE || process.env.HOME,
    env:  process.env,
  });

  proc.onData(data => {
    // 追加到历史缓冲
    scrollback += data;
    if (scrollback.length > BUF_MAX) {
      scrollback = scrollback.slice(-BUF_KEEP);
    }
    // 广播给所有已连接客户端
    broadcast({ type: 'output', data });
  });

  proc.onExit(({ exitCode }) => {
    console.log(`[bridge] claude 进程退出，code=${exitCode}`);
    broadcast({ type: 'exit', exitCode });
    scrollback = '';
    shell = null;
  });

  return proc;
}

function broadcast(msg) {
  const raw = JSON.stringify(msg);
  server.clients.forEach(c => {
    if (c.readyState === ws.WebSocket.OPEN) c.send(raw);
  });
}

// ──────────────────────────────────────────────
// WebSocket 服务器
// ──────────────────────────────────────────────
const server = new ws.WebSocketServer({ port: PORT });
printAddresses();

// 首次自动启动 shell
shell = spawnShell();

server.on('connection', client => {
  const count = server.clients.size;
  console.log(`[bridge] 客户端连接 (当前 ${count} 个)`);

  // 回放历史缓冲，让新连接立即看到之前的输出
  if (scrollback) {
    client.send(JSON.stringify({ type: 'output', data: scrollback }));
  }

  // 若之前 shell 已退出，自动重启
  if (!shell) {
    console.log('[bridge] 重新启动 claude...');
    shell = spawnShell();
  }

  // 接收来自 Android 的消息
  client.on('message', raw => {
    let msg;
    try { msg = JSON.parse(raw); } catch (_) { return; }

    // 目录跳转：不依赖 shell，单独处理
    switch (msg.type) {
      case 'list_roots':
        client.send(JSON.stringify({
          type: 'roots', reqId: msg.reqId, data: listRoots(),
        }));
        return;
      case 'search_dirs': {
        const data = searchDirs(msg.root, msg.keyword);
        client.send(JSON.stringify({
          type: 'search_result', reqId: msg.reqId, data,
        }));
        return;
      }
      case 'add_root': {
        const r = addCustomRoot(msg.label, msg.path);
        client.send(JSON.stringify({
          type: 'root_changed', reqId: msg.reqId, ok: r.ok, error: r.error,
          data: listRoots(),
        }));
        return;
      }
      case 'remove_root': {
        const ok = removeCustomRoot(msg.path);
        client.send(JSON.stringify({
          type: 'root_changed', reqId: msg.reqId, ok, data: listRoots(),
        }));
        return;
      }
    }

    // 其余消息需要 shell
    if (!shell) return;
    switch (msg.type) {
      case 'input':
        shell.write(msg.data);
        break;
      case 'resize':
        shell.resize(
          Math.max(1, Math.min(msg.cols, 250)),
          Math.max(1, Math.min(msg.rows, 80))
        );
        break;
      case 'kill':
        shell.kill();
        break;
      case 'restart':
        shell.kill();
        break;
    }
  });

  client.on('close', () => {
    console.log(`[bridge] 客户端断开 (剩余 ${server.clients.size} 个)`);
  });

  client.on('error', err => {
    console.error('[bridge] 客户端错误:', err.message);
  });
});

server.on('error', err => {
  console.error('[bridge] 服务器错误:', err.message);
  if (err.code === 'EADDRINUSE') {
    console.error(`端口 ${PORT} 已被占用，请关闭其他占用进程后重试`);
    process.exit(1);
  }
});

// 优雅退出
process.on('SIGINT', () => {
  console.log('\n[bridge] 正在关闭...');
  if (shell) shell.kill();
  server.close(() => process.exit(0));
});
