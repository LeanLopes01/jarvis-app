import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../controllers/app_ctrl.dart';
import '../services/jarvis_api.dart';

const _dayLabels = ['Seg', 'Ter', 'Qua', 'Qui', 'Sex', 'Sáb', 'Dom'];

/// Lists the routines and lets the user create, edit, switch off or delete them.
class RoutinesScreen extends StatelessWidget {
  const RoutinesScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Rotinas')),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: () => _edit(context, null),
          icon: const Icon(Icons.add),
          label: const Text('Nova rotina'),
        ),
        body: Consumer<AppCtrl>(
          builder: (context, ctrl, _) => RefreshIndicator(
            onRefresh: ctrl.refreshRoutines,
            child: ctrl.routines.isEmpty
                ? ListView(children: const [
                    Padding(
                      padding: EdgeInsets.all(32),
                      child: Text('Nenhuma rotina. Puxe para atualizar ou crie uma nova.',
                          textAlign: TextAlign.center),
                    )
                  ])
                : ListView(
                    padding: const EdgeInsets.only(bottom: 96),
                    children: [
                      const Padding(
                        padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
                        child: Text('Horários em GMT-3. O JARVIS fala em inglês.'),
                      ),
                      for (final routine in ctrl.routines)
                        ListTile(
                          title: Text('${routine.time} · ${routine.name}'),
                          subtitle: Text(
                            '${_days(routine.days)}\n${routine.prompt}',
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                          ),
                          isThreeLine: true,
                          onTap: () => _edit(context, routine),
                          trailing: Switch(
                            value: routine.enabled,
                            onChanged: (on) => _run(context, () => ctrl.saveRoutine(routine.copyWith(enabled: on))),
                          ),
                        ),
                    ],
                  ),
          ),
        ),
      );

  static String _days(List<int> days) =>
      days.length == 7 ? 'Todos os dias' : days.map((d) => _dayLabels[d]).join(', ');

  static Future<void> _run(BuildContext context, Future<void> Function() action) async {
    try {
      await action();
    } on JarvisApiException catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.detail ?? e.userMessage)));
      }
    }
  }

  static Future<void> _edit(BuildContext context, JarvisRoutine? routine) =>
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => RoutineEditor(routine: routine)));
}

class RoutineEditor extends StatefulWidget {
  const RoutineEditor({super.key, this.routine});

  final JarvisRoutine? routine;

  @override
  State<RoutineEditor> createState() => _RoutineEditorState();
}

class _RoutineEditorState extends State<RoutineEditor> {
  late final _name = TextEditingController(text: widget.routine?.name ?? '');
  late final _prompt = TextEditingController(text: widget.routine?.prompt ?? '');
  late final _location = TextEditingController(text: widget.routine?.location ?? 'Lorena, São Paulo, Brazil');
  late TimeOfDay _time = widget.routine == null
      ? const TimeOfDay(hour: 7, minute: 0)
      : TimeOfDay(hour: widget.routine!.hour, minute: widget.routine!.minute);
  late final Set<int> _days = {...?widget.routine?.days};
  late bool _enabled = widget.routine?.enabled ?? true;
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    _prompt.dispose();
    _location.dispose();
    super.dispose();
  }

  String get _timeText =>
      '${_time.hour.toString().padLeft(2, '0')}:${_time.minute.toString().padLeft(2, '0')}';

  Future<void> _save() async {
    setState(() => _saving = true);
    final ctrl = context.read<AppCtrl>();
    try {
      await ctrl.saveRoutine(JarvisRoutine(
        id: widget.routine?.id,
        name: _name.text.trim(),
        enabled: _enabled,
        time: _timeText,
        days: _days.toList()..sort(),
        prompt: _prompt.text.trim(),
        location: _location.text.trim(),
      ));
      if (mounted) Navigator.of(context).pop();
    } on JarvisApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.detail ?? e.userMessage)));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete() async {
    final id = widget.routine?.id;
    if (id == null) return;
    setState(() => _saving = true);
    await context.read<AppCtrl>().deleteRoutine(id);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: Text(widget.routine == null ? 'Nova rotina' : 'Editar rotina'),
          actions: [
            if (widget.routine?.id != null)
              IconButton(onPressed: _saving ? null : _delete, icon: const Icon(Icons.delete_outline), tooltip: 'Apagar'),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextField(controller: _name, decoration: const InputDecoration(labelText: 'Nome')),
            const SizedBox(height: 12),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Horário (GMT-3)'),
              trailing: Text(_timeText, style: Theme.of(context).textTheme.titleLarge),
              onTap: () async {
                final picked = await showTimePicker(context: context, initialTime: _time);
                if (picked != null) setState(() => _time = picked);
              },
            ),
            Wrap(
              spacing: 6,
              children: [
                for (var day = 0; day < 7; day++)
                  FilterChip(
                    label: Text(_dayLabels[day]),
                    selected: _days.contains(day),
                    onSelected: (on) => setState(() => on ? _days.add(day) : _days.remove(day)),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _prompt,
              minLines: 3,
              maxLines: 6,
              decoration: const InputDecoration(
                labelText: 'O que o JARVIS deve fazer',
                hintText: 'Ex.: Wish me good morning, tell me the weather and one news story.',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _location,
              decoration: const InputDecoration(
                labelText: 'Local para o clima',
                helperText: 'Usado quando o celular não informa a localização.',
              ),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Ativa'),
              value: _enabled,
              onChanged: (on) => setState(() => _enabled = on),
            ),
            const SizedBox(height: 12),
            FilledButton(onPressed: _saving ? null : _save, child: const Text('Salvar')),
          ],
        ),
      );
}
