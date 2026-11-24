import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/jarvis_api.dart';
import '../companion_mode.dart';

class SoftwareUpdatesScreen extends StatefulWidget {
  const SoftwareUpdatesScreen({super.key, required this.api});
  final JarvisApi api;
  @override
  State<SoftwareUpdatesScreen> createState() => _SoftwareUpdatesState();
}
class _SoftwareUpdatesState extends State<SoftwareUpdatesScreen> {
  Map<String,dynamic>? _release;
  String _message = '';
  bool _busy = false;
  int _version = 0;
  @override
  void initState() { super.initState(); unawaited(_check()); }
  Future<void> _check() async {
    setState(() => _busy = true);
    try {
      _version = await const MethodChannel('jarvis/updates').invokeMethod<int>('version') ?? 0;
      final release = await widget.api.softwareUpdates(companionMode?'companion':'primary');
      if(mounted) setState(() { _release=release; _message=''; });
    } catch (_) { if(mounted) setState(() => _message='Não foi possível consultar. O servidor pode ainda estar na versão anterior.'); }
    finally { if(mounted) setState(() => _busy=false); }
  }
  Future<void> _install() async {
    setState(() { _busy=true; _message='Baixando e verificando o pacote…'; });
    try {
      final message=await widget.api.installUpdate(_release!['sha256'] as String);
      if(mounted) setState(() => _message=message??'Pacote preparado.');
    } catch (error) { if(mounted) setState(() => _message=error is PlatformException ? error.message??'Atualização falhou.' : 'Atualização falhou.'); }
    finally { if(mounted) setState(() => _busy=false); }
  }
  @override
  Widget build(BuildContext context) => Scaffold(appBar:AppBar(title:const Text('Versão do aplicativo')),body:ListView(padding:const EdgeInsets.all(24),children:[
    Text('Canal: ${companionMode?'S23 companion':'principal'} · compilação instalada: $_version'),
    const SizedBox(height:16),
    if(_busy) const LinearProgressIndicator(),
    if(_release?['available']==true) ...[
      Text('Disponível: ${_release!['version']}',style:Theme.of(context).textTheme.headlineSmall),
      Text(_release!['changelog'] as String? ?? ''),
      const SizedBox(height:12),
      SelectableText('SHA-256: ${_release!['sha256']}'),
      FilledButton(onPressed:!_busy&&!companionMode&&(_release!['build'] as int)>_version?_install:null,child:const Text('Baixar e atualizar')),
      const Text('O pacote é verificado por hash e assinatura. O Android pede sua confirmação antes de instalar.'),
    ] else if(!_busy) Text(_release?['message'] as String? ?? 'Nenhuma versão publicada.'),
    if(_message.isNotEmpty) Padding(padding:const EdgeInsets.symmetric(vertical:16),child:Text(_message)),
    TextButton(onPressed:_busy?null:_check,child:const Text('Verificar novamente')),
  ]));
}
