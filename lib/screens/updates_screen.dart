import 'dart:async';
import 'package:flutter/material.dart';
import '../master/event_store.dart';
import '../master/master_ctrl.dart';
import '../master/models.dart';
import '../services/jarvis_api.dart';
import 'report_screen.dart';
import 'software_updates_screen.dart';

/// Durable history, independent from voice announcement state.
class UpdatesScreen extends StatefulWidget {
  const UpdatesScreen({super.key, required this.api, required this.master});
  final JarvisApi api;
  final MasterCtrl master;
  @override
  State<UpdatesScreen> createState() => _UpdatesScreenState();
}

class _UpdatesScreenState extends State<UpdatesScreen> {
  List<AgentEvent> _events = [];
  String? _error;
  bool _loading = false;
  String _filter = 'all';

  @override
  void initState() { super.initState(); unawaited(_refresh()); }

  Future<void> _refresh() async {
    if (_loading) return;
    setState(() { _loading = true; _error = null; });
    final store = await MasterStore.open();
    await store.reload();
    if (mounted) setState(() => _events = store.events);
    try {
      // History browsing must not advance the delivery cursor or mark events seen:
      // the foreground/background delivery path owns notifications and ACKs.
      var cursor = '0';
      final result = <String, AgentEvent>{for (final e in store.events) e.id:e};
      for (var pageNumber = 0; pageNumber < 20; pageNumber++) {
        final page = await widget.api.events(cursor);
        for (final raw in page.events) {
          final event = AgentEvent.fromJson(raw);
          event.read = result[event.id]?.read ?? false;
          result[event.id] = event;
        }
        if (page.events.isEmpty || page.cursor == cursor) break;
        cursor = page.cursor;
      }
      final events = result.values.toList()..sort((a,b) => b.createdAt.compareTo(a.createdAt));
      if (mounted) setState(() => _events = events);
    } catch (error) {
      if (mounted) setState(() => _error = error is JarvisApiException ? error.userMessage : 'Não foi possível atualizar. O histórico local continua disponível.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final events = _events.where((e) => _filter == 'all' || (_filter == 'waiting' ? e.isWaiting || e.kind == 'plan_ready' : !e.read)).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Atualizações'), actions:[IconButton(onPressed:()=>Navigator.of(context).push(MaterialPageRoute(builder:(_)=>SoftwareUpdatesScreen(api:widget.api))),icon:const Icon(Icons.system_update),tooltip:'Versão do aplicativo'),IconButton(onPressed:_loading?null:_refresh,icon:const Icon(Icons.refresh),tooltip:'Atualizar')]),
      body: RefreshIndicator(onRefresh:_refresh,child:ListView(padding:const EdgeInsets.all(16),children:[
        const Text('Progresso, relatórios e decisões do seu Jarvis.',style:TextStyle(color:Colors.blueGrey)),
        const SizedBox(height:16),
        Wrap(spacing:8,children:[for(final entry in {'all':'Todas','unread':'Não lidas','waiting':'Decisões'}.entries)
          ChoiceChip(label:Text(entry.value),selected:_filter==entry.key,onSelected:(_)=>setState(()=>_filter=entry.key))]),
        if(_loading) const Padding(padding:EdgeInsets.symmetric(vertical:12),child:LinearProgressIndicator()),
        if(_error!=null) Padding(padding:const EdgeInsets.symmetric(vertical:12),child:Text(_error!,style:const TextStyle(color:Colors.orange))),
        if(events.isEmpty&&!_loading) const Padding(padding:EdgeInsets.all(32),child:Text('Nenhuma atualização neste filtro.')),
        for(final event in events) Card(child:ListTile(
          leading:Icon(event.isWaiting?Icons.pending_actions:event.isProgress?Icons.sync:Icons.notifications_outlined,color:const Color(0xff69dbe7)),
          title:Text(event.title),subtitle:Text('${formatLocal(event.when)}\n${event.summary??event.kind}',maxLines:4,overflow:TextOverflow.ellipsis),
          isThreeLine:true,trailing:event.read?null:const Icon(Icons.circle,size:8,color:Color(0xff69dbe7)),
          onTap:() async { await Navigator.of(context).push(MaterialPageRoute(builder:(_)=>ReportScreen(master:widget.master,event:event))); if(mounted) setState(()=>event.read=true); await widget.master.markRead(event); },
        )),
      ])),
    );
  }
}
