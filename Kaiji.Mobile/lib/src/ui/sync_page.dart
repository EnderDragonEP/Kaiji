/// Sync with PostgreSQL: where to sync, its status, and turning it on and off.
library;

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../sync.dart' as sync;
import 'widgets.dart';

class SyncPage extends StatefulWidget {
  const SyncPage({super.key});

  @override
  State<SyncPage> createState() => _SyncPageState();
}

class _SyncPageState extends State<SyncPage> {
  late final sync.Syncer syncer;
  late final TextEditingController host, port, database, user, password;
  late bool tls;
  bool connecting = false, showPassword = false;
  String? problem;

  @override
  void initState() {
    super.initState();
    syncer = KaijiScope.read(context).syncer;
    final s = syncer.settings;
    host = TextEditingController(text: s.host);
    port = TextEditingController(text: '${s.port}');
    database = TextEditingController(text: s.database);
    user = TextEditingController(text: s.user);
    password = TextEditingController();
    tls = s.tls;
    if (syncer.enabled) syncer.password().then((saved) => password.text = saved);
  }

  @override
  void dispose() {
    for (final c in [host, port, database, user, password]) {
      c.dispose();
    }
    super.dispose();
  }

  sync.SyncSettings get _settings => sync.SyncSettings(
        host: host.text.trim(),
        port: int.tryParse(port.text.trim()) ?? 5432,
        database: database.text.trim(),
        user: user.text.trim(),
        tls: tls,
      );

  bool get _complete =>
      _settings.host.isNotEmpty && _settings.database.isNotEmpty && _settings.user.isNotEmpty &&
      int.tryParse(port.text.trim()) != null;

  Future<void> _connect() async {
    final state = KaijiScope.read(context);
    final s = _settings;
    setState(() {
      connecting = true;
      problem = null;
    });
    bool serverEmpty;
    try {
      final server = s.remote(password.text);
      await server.open();
      try {
        serverEmpty = await server.prepare();
      } finally {
        await server.close();
      }
    } on sync.SyncError catch (e) {
      setState(() {
        connecting = false;
        problem = e.detail.isEmpty ? e.message : '${e.message}\n${e.detail}';
      });
      return;
    }
    setState(() => connecting = false);
    final db = state.store.db;
    String? first;
    if (syncer.enabled && syncer.settings.sameServer(s)) {
      first = null; // carry on with the same server
    } else if (serverEmpty) {
      first = 'replace';
    } else if (!await sync.hasOwnData(db)) {
      first = 'take';
    } else {
      if (!mounted) return;
      first = await _askWhich(context, s.host);
      if (first == null) return;
    }
    String? before; // what Undo puts back
    if (first == 'take' && await sync.hasOwnData(db)) {
      before = p.join((await getTemporaryDirectory()).path, 'before sync.db');
      await state.store.backupTo(before);
    }
    await syncer.turnOn(s, password.text, first);
    if (before != null) {
      showUndo("This phone now has the server's data", () => state.restore(before!));
    } else {
      showMessage('Sync is on');
    }
  }

  Future<String?> _askWhich(BuildContext context, String host) => showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Which data should Kaiji keep?'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('$host already has Kaiji data, and so does this phone. One of them replaces the other, so '
                "they don't double up."),
            const SizedBox(height: 8),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text("The server's data"),
              subtitle: const Text("This phone gets the server's data. Undo on the notice that follows puts "
                  "this phone's back, on the server too."),
              onTap: () => Navigator.pop(context, 'take'),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text("This phone's data"),
              subtitle: const Text("The server gets this phone's data, and your other devices get it when they "
                  'next sync.'),
              onTap: () => Navigator.pop(context, 'replace'),
            ),
          ]),
          actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel'))],
        ),
      );

  Future<void> _turnOff() async {
    if (await confirm(context, 'Turn off sync?',
        'Kaiji on this phone keeps its data, and so does the server, but they no longer share changes. The '
            'saved password is removed.',
        yes: 'Turn off')) {
      await syncer.turnOff();
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    InputDecoration field(String label, {String? hint}) =>
        InputDecoration(labelText: label, hintText: hint, border: const OutlineInputBorder());
    return Scaffold(
      appBar: AppBar(title: const Text('Sync with PostgreSQL')),
      body: ListenableBuilder(
        listenable: syncer,
        builder: (context, _) => ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 32), children: [
          Text('Kaiji on your phone and on your PC can share their data through your PostgreSQL server. Each '
              'keeps its own copy and works without the server; changes go across whenever it can be reached.',
              style: text.bodyLarge),
          if (syncer.state != 'off') ...[
            const SizedBox(height: 12),
            Card.outlined(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(syncer.describe(), style: text.bodyMedium),
                  Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                    TextButton(onPressed: _turnOff, child: const Text('Turn off')),
                    TextButton.icon(
                      icon: const Icon(Icons.sync),
                      label: const Text('Sync now'),
                      onPressed: syncer.busy ? null : () => syncer.sync(manual: true),
                    ),
                  ]),
                ]),
              ),
            ),
          ],
          const SizedBox(height: 20),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: TextField(
                controller: host,
                keyboardType: TextInputType.url,
                autocorrect: false,
                decoration: field('Server', hint: 'Name or IP address'),
                onChanged: (_) => setState(() {}),
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: 96,
              child: TextField(
                controller: port,
                keyboardType: TextInputType.number,
                decoration: field('Port'),
                onChanged: (_) => setState(() {}),
              ),
            ),
          ]),
          const SizedBox(height: 16),
          TextField(
            controller: database,
            autocorrect: false,
            decoration: field('Database'),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: user,
            autocorrect: false,
            decoration: field('User name'),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: password,
            obscureText: !showPassword,
            autocorrect: false,
            enableSuggestions: false,
            decoration: field('Password').copyWith(
              suffixIcon: IconButton(
                tooltip: showPassword ? 'Hide password' : 'Show password',
                icon: Icon(showPassword ? Icons.visibility_off_outlined : Icons.visibility_outlined),
                onPressed: () => setState(() => showPassword = !showPassword),
              ),
            ),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Encrypted connection (TLS)'),
            subtitle: const Text("Turn off only if the server doesn't take encrypted connections"),
            value: tls,
            onChanged: (on) => setState(() => tls = on),
          ),
          if (problem != null) ...[
            const SizedBox(height: 4),
            Text(problem!, style: text.bodyMedium?.copyWith(color: scheme.error)),
          ],
          const SizedBox(height: 16),
          FilledButton(
            onPressed: connecting || !_complete ? null : _connect,
            child: connecting
                ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : Text(syncer.state == 'off' ? 'Connect' : 'Save and connect'),
          ),
          const SizedBox(height: 12),
          Text("The password is kept in this phone's secure storage, not in Kaiji's backups. Sync works where the "
              'server can be reached, such as your home Wi-Fi; changes made elsewhere wait and go up later.',
              style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
        ]),
      ),
    );
  }
}
