import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:xterm/xterm.dart';

// ──────────────────────────────────────────────
// 入口
// ──────────────────────────────────────────────
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 锁定竖屏
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  runApp(const ClaudeMonitorApp());
}

// ──────────────────────────────────────────────
// 连接模式
// ──────────────────────────────────────────────
enum ConnectMode { lan, tailscale }

extension ConnectModeExt on ConnectMode {
  String get label => this == ConnectMode.lan ? '局域网' : 'Tailscale';
  String get hint  => this == ConnectMode.lan ? '192.168.x.x' : '100.x.x.x';
  String get prefKey => this == ConnectMode.lan ? 'ip_lan' : 'ip_ts';
}

// ──────────────────────────────────────────────
// 颜色常量（Dracula 风格终端主题）
// ──────────────────────────────────────────────
const _bg        = Color(0xFF0D0D0D);
const _surface   = Color(0xFF1A1A1A);
const _surface2  = Color(0xFF252525);
const _green     = Color(0xFF00CC66);
const _orange    = Color(0xFFFF9944);
const _red       = Color(0xFFFF5555);
const _textPri   = Color(0xFFE0E0E0);
const _textSec   = Color(0xFF888888);

const _termTheme = TerminalTheme(
  cursor:        Color(0xFF00FF88),
  selection:     Color(0x4400AA44),
  foreground:    Color(0xFFE0E0E0),
  background:    _bg,
  black:         Color(0xFF21222C),
  red:           Color(0xFFFF5555),
  green:         Color(0xFF50FA7B),
  yellow:        Color(0xFFF1FA8C),
  blue:          Color(0xFF6272A4),
  magenta:       Color(0xFFFF79C6),
  cyan:          Color(0xFF8BE9FD),
  white:         Color(0xFFBBBBBB),
  brightBlack:   Color(0xFF666666),
  brightRed:     Color(0xFFFF6E6E),
  brightGreen:   Color(0xFF69FF94),
  brightYellow:  Color(0xFFFFFFA5),
  brightBlue:    Color(0xFFD6ACFF),
  brightMagenta: Color(0xFFFF92DF),
  brightCyan:    Color(0xFFA4FFFF),
  brightWhite:   Color(0xFFFFFFFF),
  searchHitBackground:        Color(0xFF3A4E5C),
  searchHitBackgroundCurrent: Color(0xFFFFB86C),
  searchHitForeground:        Color(0xFF0D0D0D),
);

// ──────────────────────────────────────────────
// App 根
// ──────────────────────────────────────────────
class ClaudeMonitorApp extends StatelessWidget {
  const ClaudeMonitorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Claude Monitor',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        scaffoldBackgroundColor: _bg,
        colorScheme: const ColorScheme.dark(
          primary: _green,
          surface: _surface,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: _surface,
          elevation: 0,
          titleTextStyle: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w500,
            color: _textPri,
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: _surface2,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: Color(0xFF333333)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: Color(0xFF333333)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: _green, width: 1.5),
          ),
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          isDense: true,
          hintStyle: const TextStyle(color: Color(0xFF444444), fontSize: 13),
        ),
      ),
      home: const MonitorPage(),
    );
  }
}

// ──────────────────────────────────────────────
// 主页面
// ──────────────────────────────────────────────
class MonitorPage extends StatefulWidget {
  const MonitorPage({super.key});

  @override
  State<MonitorPage> createState() => _MonitorPageState();
}

class _MonitorPageState extends State<MonitorPage> {
  // 终端
  late final Terminal _terminal;
  final _termCtrl = TerminalController();

  // 连接状态
  WebSocketChannel? _channel;
  StreamSubscription? _sub;
  bool _connected  = false;
  bool _connecting = false;
  String _status   = '未连接';

  // 配置
  ConnectMode _mode = ConnectMode.lan;
  final _ipCtrl = <ConnectMode, TextEditingController>{
    ConnectMode.lan:       TextEditingController(),
    ConnectMode.tailscale: TextEditingController(),
  };

  // 自动重连
  Timer? _reconnectTimer;
  bool _autoReconnect = false;
  int  _reconnectSec  = 0;

  @override
  void initState() {
    super.initState();
    _terminal = Terminal(maxLines: 10000);
    _loadPrefs();
  }

  @override
  void dispose() {
    _disconnect(notify: false);
    _reconnectTimer?.cancel();
    for (final c in _ipCtrl.values) c.dispose();
    super.dispose();
  }

  // ── 持久化 ──────────────────────────────────
  Future<void> _loadPrefs() async {
    final p = await SharedPreferences.getInstance();
    setState(() {
      _ipCtrl[ConnectMode.lan]!.text       = p.getString('ip_lan') ?? '';
      _ipCtrl[ConnectMode.tailscale]!.text = p.getString('ip_ts')  ?? '';
      _mode = ConnectMode.values[p.getInt('mode') ?? 0];
      _autoReconnect = p.getBool('auto_reconnect') ?? false;
    });
  }

  Future<void> _savePrefs() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('ip_lan', _ipCtrl[ConnectMode.lan]!.text);
    await p.setString('ip_ts',  _ipCtrl[ConnectMode.tailscale]!.text);
    await p.setInt('mode',      _mode.index);
    await p.setBool('auto_reconnect', _autoReconnect);
  }

  // ── 连接逻辑 ─────────────────────────────────
  String get _currentIp => _ipCtrl[_mode]!.text.trim();

  Future<void> _connect() async {
    if (_connecting || _currentIp.isEmpty) return;
    _reconnectTimer?.cancel();

    setState(() {
      _connecting = true;
      _status = '连接中...';
    });

    await _savePrefs();
    final uri = Uri.parse('ws://$_currentIp:8765');

    try {
      _channel = WebSocketChannel.connect(uri);
      await _channel!.ready;

      _sub = _channel!.stream.listen(
        _onMessage,
        onDone:  () => _onDisconnect(),
        onError: (_) => _onDisconnect(),
      );

      // 键盘输入 → 发送
      _terminal.onOutput = (data) {
        _channel?.sink.add(jsonEncode({'type': 'input', 'data': data}));
      };

      // 终端尺寸变化 → 通知 bridge
      _terminal.onResize = (cols, rows, pw, ph) {
        _channel?.sink.add(jsonEncode({
          'type': 'resize',
          'cols': cols,
          'rows': rows,
        }));
      };

      setState(() {
        _connected  = true;
        _connecting = false;
        _status     = '${_mode.label} · $_currentIp';
      });
    } catch (e) {
      setState(() {
        _connecting = false;
        _status     = '连接失败';
      });
      _terminal.write('\x1b[31m[错误] 无法连接到 $_currentIp:8765\x1b[0m\r\n');
      _terminal.write('\x1b[33m请确认桥接服务正在运行，且设备在同一网络\x1b[0m\r\n');
      if (_autoReconnect) _scheduleReconnect();
    }
  }

  void _onMessage(dynamic raw) {
    try {
      final msg = jsonDecode(raw as String) as Map;
      switch (msg['type']) {
        case 'output':
          _terminal.write(msg['data'] as String);
        case 'exit':
          _terminal.write('\r\n\x1b[33m[claude 进程已退出 code=${msg['exitCode']}]\x1b[0m\r\n');
      }
    } catch (_) {}
  }

  void _onDisconnect() {
    if (!_connected && !_connecting) return;
    _terminal.write('\r\n\x1b[31m[连接断开]\x1b[0m\r\n');
    _disconnect(notify: false);
    if (_autoReconnect) _scheduleReconnect();
  }

  void _disconnect({bool notify = true}) {
    _reconnectTimer?.cancel();
    _sub?.cancel();
    _channel?.sink.close();
    _channel = null;
    _terminal.onOutput = null;
    if (notify) _terminal.write('\r\n\x1b[33m[已断开]\x1b[0m\r\n');
    if (mounted) {
      setState(() {
        _connected  = false;
        _connecting = false;
        _status     = '未连接';
        _reconnectSec = 0;
      });
    }
  }

  // ── 自动重连倒计时 ────────────────────────────
  void _scheduleReconnect({int delaySec = 5}) {
    _reconnectSec = delaySec;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) { t.cancel(); return; }
      setState(() => _reconnectSec--);
      if (_reconnectSec <= 0) {
        t.cancel();
        _connect();
      }
    });
  }

  // ── 快捷操作 ──────────────────────────────────
  void _sendCtrlC() {
    _channel?.sink.add(jsonEncode({'type': 'input', 'data': '\x03'}));
  }

  void _sendEnter() {
    _channel?.sink.add(jsonEncode({'type': 'input', 'data': '\r'}));
  }

  void _clearTerminal() => _terminal.buffer.clear();

  // ── 构建 UI ───────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        title: Row(children: [
          // 状态指示灯
          AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            width: 8, height: 8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _connected
                  ? _green
                  : _connecting
                      ? _orange
                      : const Color(0xFF444444),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _connected ? _status : 'Claude Code Monitor',
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ]),
        actions: [
          if (_connected) ...[
            // Ctrl+C
            _AppBarBtn(
              icon: Icons.stop_rounded,
              color: _orange,
              tooltip: 'Ctrl+C',
              onTap: _sendCtrlC,
            ),
            // 断开
            _AppBarBtn(
              icon: Icons.link_off_rounded,
              color: _red,
              tooltip: '断开连接',
              onTap: () => _disconnect(),
            ),
          ],
          // 清屏
          _AppBarBtn(
            icon: Icons.cleaning_services_rounded,
            color: _textSec,
            tooltip: '清屏',
            onTap: _clearTerminal,
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Column(children: [
        // ── 连接面板 ────────────────────────────
        _ConnectionPanel(
          mode:       _mode,
          ipCtrls:    _ipCtrl,
          connected:  _connected,
          connecting: _connecting,
          status:     _status,
          autoReconnect:    _autoReconnect,
          reconnectCountdown: _reconnectSec,
          onModeChanged: (m) => setState(() => _mode = m),
          onConnect:         _connect,
          onDisconnect:      () => _disconnect(),
          onAutoReconnectChanged: (v) => setState(() => _autoReconnect = v),
        ),

        const Divider(height: 1, thickness: 1, color: Color(0xFF222222)),

        // ── 终端 ────────────────────────────────
        Expanded(
          child: TerminalView(
            _terminal,
            controller: _termCtrl,
            autofocus: true,
            theme: _termTheme,
            padding: const EdgeInsets.all(4),
          ),
        ),

        // ── 底部快捷键栏 ─────────────────────────
        if (_connected) _QuickBar(
          onCtrlC:  _sendCtrlC,
          onEnter:  _sendEnter,
          onTab:    () => _channel?.sink.add(jsonEncode({'type': 'input', 'data': '\t'})),
          onEscape: () => _channel?.sink.add(jsonEncode({'type': 'input', 'data': '\x1b'})),
          onUp:     () => _channel?.sink.add(jsonEncode({'type': 'input', 'data': '\x1b[A'})),
          onDown:   () => _channel?.sink.add(jsonEncode({'type': 'input', 'data': '\x1b[B'})),
        ),
      ]),
    );
  }
}

// ──────────────────────────────────────────────
// 连接面板组件
// ──────────────────────────────────────────────
class _ConnectionPanel extends StatelessWidget {
  final ConnectMode mode;
  final Map<ConnectMode, TextEditingController> ipCtrls;
  final bool connected, connecting, autoReconnect;
  final String status;
  final int reconnectCountdown;
  final ValueChanged<ConnectMode> onModeChanged;
  final VoidCallback onConnect, onDisconnect;
  final ValueChanged<bool> onAutoReconnectChanged;

  const _ConnectionPanel({
    required this.mode,
    required this.ipCtrls,
    required this.connected,
    required this.connecting,
    required this.status,
    required this.autoReconnect,
    required this.reconnectCountdown,
    required this.onModeChanged,
    required this.onConnect,
    required this.onDisconnect,
    required this.onAutoReconnectChanged,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      color: _surface,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: connected ? _buildConnectedBar() : _buildInputPanel(),
    );
  }

  Widget _buildConnectedBar() {
    return Row(children: [
      const Icon(Icons.check_circle_rounded, color: _green, size: 14),
      const SizedBox(width: 6),
      Expanded(
        child: Text(status, style: const TextStyle(fontSize: 12, color: _textSec)),
      ),
      if (reconnectCountdown > 0)
        Text('${reconnectCountdown}s 后重连', style: const TextStyle(fontSize: 11, color: _orange)),
    ]);
  }

  Widget _buildInputPanel() {
    return Column(mainAxisSize: MainAxisSize.min, children: [
      // 模式切换 + 自动重连
      Row(children: [
        _ModeToggle(current: mode, onChanged: onModeChanged),
        const Spacer(),
        const Text('自动重连', style: TextStyle(fontSize: 11, color: _textSec)),
        const SizedBox(width: 4),
        Transform.scale(
          scale: 0.75,
          child: Switch(
            value: autoReconnect,
            onChanged: onAutoReconnectChanged,
            activeColor: _green,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ),
      ]),
      const SizedBox(height: 8),
      // IP 输入 + 连接按钮
      Row(children: [
        Expanded(
          child: TextField(
            controller: ipCtrls[mode],
            style: const TextStyle(fontSize: 13, fontFamily: 'monospace', color: _textPri),
            decoration: InputDecoration(hintText: mode.hint),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            onSubmitted: (_) => onConnect(),
          ),
        ),
        const SizedBox(width: 8),
        _ConnectButton(
          connecting: connecting,
          countdown:  reconnectCountdown,
          onTap: connecting ? null : onConnect,
        ),
      ]),
    ]);
  }
}

// ──────────────────────────────────────────────
// 模式切换器
// ──────────────────────────────────────────────
class _ModeToggle extends StatelessWidget {
  final ConnectMode current;
  final ValueChanged<ConnectMode> onChanged;

  const _ModeToggle({required this.current, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF111111),
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.all(2),
      child: Row(mainAxisSize: MainAxisSize.min, children: ConnectMode.values.map((m) {
        final sel = m == current;
        return GestureDetector(
          onTap: () => onChanged(m),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
            decoration: BoxDecoration(
              color: sel ? _green : Colors.transparent,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              m.label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: sel ? Colors.black : _textSec,
              ),
            ),
          ),
        );
      }).toList()),
    );
  }
}

// ──────────────────────────────────────────────
// 连接按钮
// ──────────────────────────────────────────────
class _ConnectButton extends StatelessWidget {
  final bool connecting;
  final int countdown;
  final VoidCallback? onTap;

  const _ConnectButton({
    required this.connecting,
    required this.countdown,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        height: 36,
        width: 76,
        decoration: BoxDecoration(
          color: connecting ? _surface2 : _green,
          borderRadius: BorderRadius.circular(8),
        ),
        alignment: Alignment.center,
        child: connecting
          ? const SizedBox(
              width: 16, height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2, color: _green,
              ),
            )
          : Text(
              countdown > 0 ? '${countdown}s' : '连接',
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Colors.black,
              ),
            ),
      ),
    );
  }
}

// ──────────────────────────────────────────────
// AppBar 图标按钮
// ──────────────────────────────────────────────
class _AppBarBtn extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String tooltip;
  final VoidCallback onTap;

  const _AppBarBtn({
    required this.icon,
    required this.color,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: IconButton(
        icon: Icon(icon, size: 20, color: color),
        onPressed: onTap,
        splashRadius: 20,
      ),
    );
  }
}

// ──────────────────────────────────────────────
// 底部快捷键栏
// ──────────────────────────────────────────────
class _QuickBar extends StatelessWidget {
  final VoidCallback onCtrlC, onEnter, onTab, onEscape, onUp, onDown;

  const _QuickBar({
    required this.onCtrlC,
    required this.onEnter,
    required this.onTab,
    required this.onEscape,
    required this.onUp,
    required this.onDown,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: _surface,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
      child: Row(children: [
        _KeyBtn(label: 'Ctrl+C', color: _orange, onTap: onCtrlC),
        _KeyBtn(label: 'Tab',    onTap: onTab),
        _KeyBtn(label: 'Esc',    onTap: onEscape),
        const Spacer(),
        _KeyBtn(label: '↑', onTap: onUp),
        _KeyBtn(label: '↓', onTap: onDown),
        _KeyBtn(label: '↵ Enter', color: _green, onTap: onEnter),
      ]),
    );
  }
}

class _KeyBtn extends StatelessWidget {
  final String label;
  final Color? color;
  final VoidCallback onTap;

  const _KeyBtn({required this.label, required this.onTap, this.color});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: _surface2,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: color?.withOpacity(0.4) ?? const Color(0xFF333333),
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w500,
              color: color ?? _textSec,
              fontFamily: 'monospace',
            ),
          ),
        ),
      ),
    );
  }
}
