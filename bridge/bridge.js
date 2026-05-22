/**
 * Claude Code Bridge
 * 将 Claude Code CLI 通过 WebSocket 暴露给 Android 客户端
 * 依赖: npm install ws node-pty
 */

const pty  = require('node-pty');
const ws   = require('ws');
const os   = require('os');

// ──────────────────────────────────────────────
// 配置
// ──────────────────────────────────────────────
const PORT       = 8765;
const BUF_MAX    = 60_000;   // 历史缓冲上限（字节）
const BUF_KEEP   = 36_000;   // 超限后保留的尾部大小

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
    try {
      const msg = JSON.parse(raw);
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
    } catch (_) {}
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
