import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';

import '../../services/vistoria_chat_session_service.dart';
import '../camera/camera_page.dart';
import '../orcamento/orcamento_calculo.dart';
import '../orcamento/orcamento_table_page.dart';

const int kBulkMaxPhotos = 10;
const int kBulkMaxAudios = 10;

// Chave fixa do item de texto livre no rascunho (só existe um por vez).
// Nunca pode começar E terminar com "__": o Firestore recusa esse padrão
// de nome de campo (reservado internamente) em caminhos tipo
// 'envioEmMassaRascunho.<chave>.status' usados por markEnvioEmMassaRascunhoItemEnviado.
const String kBulkTextRascunhoKey = 'bulk_texto_livre';

/// Explica por que o microfone é necessário quando a permissão foi negada e
/// oferece abrir as configurações do aparelho. Usado aqui e no chat guiado.
Future<void> showMicrophonePermissionDialog(BuildContext context) async {
  final permanentlyDenied = await Permission.microphone.isPermanentlyDenied;

  if (!context.mounted) return;

  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Microfone sem permissão'),
      content: Text(
        permanentlyDenied
            ? 'O acesso ao microfone está bloqueado. Para gravar os áudios '
                'da vistoria, libere o microfone nas configurações do '
                'aparelho.'
            : 'O Argos precisa do microfone para gravar os áudios da '
                'vistoria. Libere o acesso para continuar.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('Agora não'),
        ),
        TextButton(
          onPressed: () {
            Navigator.of(dialogContext).pop();
            openAppSettings();
          },
          child: const Text('Abrir configurações'),
        ),
      ],
    ),
  );
}

/// Gera um ID local único pra um item do pacote (foto, áudio ou orçamento).
String _newLocalId() =>
    'bulk_${DateTime.now().microsecondsSinceEpoch}';

/// Item de orçamento dentro do pacote de envio em massa. `dados` é o mapa
/// devolvido pela `OrcamentoTablePage` (peça, quantidade, horas, valor da
/// hora congelado e totais) — o `localId` é o mesmo `id` do item.
class BulkOrcamentoItem {
  final String localId;
  final Map<String, dynamic> dados;

  const BulkOrcamentoItem({required this.localId, required this.dados});

  String get peca => (dados['peca'] ?? '').toString();

  double get valorTotal =>
      (dados['valorTotal'] is num) ? (dados['valorTotal'] as num).toDouble() : 0;

  // Rascunho gravado antes do valor da hora configurável não tem
  // `valorTotal`: precisa passar pela tabela antes de ir com mão de obra
  // zerada.
  bool get precisaRevisao => dados['valorTotal'] is! num;

  Map<String, dynamic> toRascunhoItem() => {
        ...dados,
        'id': localId,
        'tipo': 'orcamento',
        'status': 'rascunho',
      };

  static BulkOrcamentoItem? fromRascunho(String localId, Map data) {
    final dados = data.map((key, value) => MapEntry(key.toString(), value))
      ..remove('tipo')
      ..remove('status');

    if ((dados['peca'] ?? '').toString().trim().isEmpty) return null;

    return BulkOrcamentoItem(localId: localId, dados: {...dados, 'id': localId});
  }
}

/// Foto do pacote de envio em massa, já copiada pro diretório persistente do app.
class BulkPhotoItem {
  final String localId;
  final String path;

  const BulkPhotoItem({required this.localId, required this.path});

  Map<String, dynamic> toRascunhoItem() => {
        'tipo': 'foto',
        'status': 'rascunho',
        'localPath': path,
      };
}

/// Áudio gravado do pacote de envio em massa.
class BulkAudioItem {
  final String localId;
  final String path;
  final int durationSeconds;

  const BulkAudioItem({
    required this.localId,
    required this.path,
    required this.durationSeconds,
  });

  Map<String, dynamic> toRascunhoItem() => {
        'tipo': 'audio',
        'status': 'rascunho',
        'localPath': path,
        'durationSeconds': durationSeconds,
      };
}

/// Resultado final do modal de envio em massa: tudo que o mecânico montou, pronto pra upload.
class BulkUploadResult {
  final List<BulkPhotoItem> photos;
  final List<BulkAudioItem> audios;
  final String text;
  final List<BulkOrcamentoItem> orcamentoItems;

  const BulkUploadResult({
    required this.photos,
    required this.audios,
    required this.text,
    required this.orcamentoItems,
  });
}

/// Converte um rascunho persistido (`envioEmMassaRascunho`) num `BulkUploadResult` pronto pra (re)enviar.
BulkUploadResult buildBulkUploadResultFromRascunho(
  Map<String, dynamic> rascunho, {
  void Function(String tipo)? onMissingFile,
}) {
  final photos = <BulkPhotoItem>[];
  final audios = <BulkAudioItem>[];
  final orcamentoItems = <BulkOrcamentoItem>[];
  var text = '';

  for (final entry in rascunho.entries) {
    final localId = entry.key;
    final data = entry.value;

    if (data is! Map) continue;
    if (data['status'] == 'enviado') continue;

    switch (data['tipo']?.toString() ?? '') {
      case 'foto':
        final path = data['localPath']?.toString() ?? '';
        if (path.isNotEmpty && File(path).existsSync()) {
          photos.add(BulkPhotoItem(localId: localId, path: path));
        } else {
          onMissingFile?.call('foto');
        }
      case 'audio':
        final path = data['localPath']?.toString() ?? '';
        if (path.isNotEmpty && File(path).existsSync()) {
          audios.add(
            BulkAudioItem(
              localId: localId,
              path: path,
              durationSeconds: (data['durationSeconds'] is num)
                  ? (data['durationSeconds'] as num).toInt()
                  : 0,
            ),
          );
        } else {
          onMissingFile?.call('áudio');
        }
      case 'orcamento':
        final item = BulkOrcamentoItem.fromRascunho(localId, data);
        if (item != null) orcamentoItems.add(item);
      case 'texto':
        text = data['text']?.toString() ?? '';
    }
  }

  return BulkUploadResult(
    photos: photos,
    audios: audios,
    text: text,
    orcamentoItems: orcamentoItems,
  );
}

/// Modal de composição do modo "enviar tudo de uma vez": fotos, áudios, texto e orçamento.
class BulkUploadSheet extends StatefulWidget {
  final String vistoriaDocId;

  // Itens que sobreviveram de uma tentativa anterior interrompida.
  final Map<String, dynamic> initialDraft;

  const BulkUploadSheet({
    super.key,
    required this.vistoriaDocId,
    this.initialDraft = const {},
  });

  static Future<BulkUploadResult?> show(
    BuildContext context, {
    required String vistoriaDocId,
    Map<String, dynamic> initialDraft = const {},
  }) {
    return showModalBottomSheet<BulkUploadResult>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => BulkUploadSheet(
        vistoriaDocId: vistoriaDocId,
        initialDraft: initialDraft,
      ),
    );
  }

  @override
  State<BulkUploadSheet> createState() => _BulkUploadSheetState();
}

/// Estado do modal: mantém as listas de itens e sincroniza cada mudança com o rascunho no Firestore.
class _BulkUploadSheetState extends State<BulkUploadSheet> {
  final List<BulkPhotoItem> _photos = [];
  final List<BulkAudioItem> _audios = [];
  final List<BulkOrcamentoItem> _orcamentoItems = [];
  final List<String> _missingLocalFilesWarning = [];
  final TextEditingController _textController = TextEditingController();

  final AudioRecorder _recorder = AudioRecorder();
  bool _isRecording = false;
  String? _currentRecordingPath;
  Timer? _recordingTimer;
  int _recordingSeconds = 0;
  Timer? _textDebounce;

  @override
  void initState() {
    super.initState();
    _loadInitialDraft();
  }

  /// Pré-popula as listas a partir do rascunho recebido e avisa sobre arquivos perdidos.
  void _loadInitialDraft() {
    final result = buildBulkUploadResultFromRascunho(
      widget.initialDraft,
      onMissingFile: _missingLocalFilesWarning.add,
    );

    _photos.addAll(result.photos);
    _audios.addAll(result.audios);
    _orcamentoItems.addAll(result.orcamentoItems);
    _textController.text = result.text;

    if (_missingLocalFilesWarning.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Alguns arquivos do rascunho anterior não foram encontrados '
              '(${_missingLocalFilesWarning.join(", ")}) -- precisam ser '
              'refeitos.',
            ),
          ),
        );
      });
    }
  }

  /// Grava/atualiza um item no rascunho persistido do Firestore.
  void _syncItem(String localId, Map<String, dynamic> item) {
    unawaited(
      VistoriaChatSessionService.instance.upsertEnvioEmMassaRascunhoItem(
        vistoriaDocId: widget.vistoriaDocId,
        localId: localId,
        item: item,
      ),
    );
  }

  /// Confirma antes de tirar uma foto ou áudio do pacote (o botão de remover
  /// fica em cima da miniatura e era fácil tocar sem querer).
  Future<bool> _confirmarRemocao(String oQue) async {
    final remover = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Remover $oQue?'),
        content: const Text('Ele sai do pacote e não será enviado.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Manter'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
            child: const Text('Remover'),
          ),
        ],
      ),
    );
    return remover ?? false;
  }

  /// Remove um item do rascunho persistido do Firestore.
  void _removeSyncedItem(String localId) {
    unawaited(
      VistoriaChatSessionService.instance.removeEnvioEmMassaRascunhoItem(
        vistoriaDocId: widget.vistoriaDocId,
        localId: localId,
      ),
    );
  }

  @override
  void dispose() {
    _recordingTimer?.cancel();
    _textDebounce?.cancel();
    _textController.dispose();
    if (_isRecording) {
      _recorder.stop();
    }
    _recorder.dispose();
    super.dispose();
  }

  /// Abre a câmera, copia as fotos tiradas pro diretório persistente e as adiciona à lista.
  Future<void> _addPhotos() async {
    if (_photos.length >= kBulkMaxPhotos) return;

    final result = await Navigator.of(
      context,
    ).push<List<XFile>?>(MaterialPageRoute(builder: (_) => const CameraPage()));

    if (result == null || result.isEmpty || !mounted) return;

    final directory = await getApplicationDocumentsDirectory();
    final bulkDirectory = Directory('${directory.path}/argos_bulk_pendente');

    if (!await bulkDirectory.exists()) {
      await bulkDirectory.create(recursive: true);
    }

    final remaining = kBulkMaxPhotos - _photos.length;
    final newItems = <BulkPhotoItem>[];

    for (final photo in result.take(remaining)) {
      final localId = _newLocalId();
      final persistedPath = '${bulkDirectory.path}/$localId.jpg';

      try {
        await File(photo.path).copy(persistedPath);
      } catch (_) {
        continue;
      }

      final item = BulkPhotoItem(localId: localId, path: persistedPath);
      newItems.add(item);
      _syncItem(localId, item.toRascunhoItem());
    }

    if (!mounted || newItems.isEmpty) return;

    setState(() => _photos.addAll(newItems));
  }

  /// Inicia ou para a gravação de um áudio pro pacote.
  Future<void> _toggleRecording() async {
    if (_isRecording) {
      await _stopRecording();
      return;
    }

    if (_audios.length >= kBulkMaxAudios) return;

    final hasPermission = await _recorder.hasPermission();

    if (!hasPermission) {
      if (!mounted) return;
      await showMicrophonePermissionDialog(context);
      return;
    }

    final String path;

    try {
      final directory = await getApplicationDocumentsDirectory();
      final audioDirectory = Directory('${directory.path}/argos_audios');

      if (!await audioDirectory.exists()) {
        await audioDirectory.create(recursive: true);
      }

      path =
          '${audioDirectory.path}/argos_audio_bulk_${DateTime.now().millisecondsSinceEpoch}.m4a';

      await _recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          bitRate: 128000,
          sampleRate: 44100,
          numChannels: 1,
        ),
        path: path,
      );
    } catch (e) {
      debugPrint('Erro ao iniciar gravação no envio em massa: $e');

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Não foi possível iniciar a gravação. Tente novamente.'),
          backgroundColor: Colors.redAccent,
        ),
      );
      return;
    }

    if (!mounted) return;

    _currentRecordingPath = path;

    setState(() {
      _isRecording = true;
      _recordingSeconds = 0;
    });

    _recordingTimer?.cancel();
    _recordingTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _recordingSeconds++);
    });
  }

  /// Finaliza a gravação atual e adiciona o áudio resultante à lista.
  Future<void> _stopRecording() async {
    _recordingTimer?.cancel();

    final duration = _recordingSeconds;
    String? recordedPath;

    try {
      recordedPath = await _recorder.stop();
    } catch (_) {}

    final path = recordedPath ?? _currentRecordingPath;

    if (!mounted) return;

    setState(() {
      _isRecording = false;
      _recordingSeconds = 0;
    });

    if (path == null || duration <= 0) return;
    if (_audios.length >= kBulkMaxAudios) return;

    final localId = _newLocalId();
    final item = BulkAudioItem(
      localId: localId,
      path: path,
      durationSeconds: duration,
    );

    _syncItem(localId, item.toRascunhoItem());

    setState(() => _audios.add(item));
  }

  /// Sincroniza o texto livre no rascunho com debounce, removendo-o se ficar vazio.
  void _onTextChanged(String value) {
    setState(() {});

    _textDebounce?.cancel();
    _textDebounce = Timer(const Duration(milliseconds: 600), () {
      final trimmed = value.trim();

      if (trimmed.isEmpty) {
        _removeSyncedItem(kBulkTextRascunhoKey);
        return;
      }

      _syncItem(kBulkTextRascunhoKey, {
        'tipo': 'texto',
        'status': 'rascunho',
        'text': trimmed,
      });
    });
  }

  /// Abre a tabela de orçamento (a mesma do fluxo guiado) com os itens
  /// atuais e substitui a lista pelo que o mecânico confirmar.
  Future<void> _editOrcamento() async {
    final modelo = await _modeloVeiculo();

    if (!mounted) return;

    final result = await Navigator.of(context).push<List<Map<String, dynamic>>?>(
      MaterialPageRoute(
        builder: (_) => OrcamentoTablePage(
          itensIniciais: _orcamentoItems
              .map((item) => OrcamentoItemDraft.fromMap(item.dados))
              .toList(),
          modeloVeiculo: modelo,
          submitLabel: 'Salvar orçamento',
          vistoriaDocId: widget.vistoriaDocId,
        ),
      ),
    );

    if (result == null || !mounted) return;

    final novos = result
        .map((dados) => BulkOrcamentoItem(
              localId: dados['id'].toString(),
              dados: dados,
            ))
        .toList();
    final novosIds = novos.map((item) => item.localId).toSet();

    for (final antigo in _orcamentoItems) {
      if (!novosIds.contains(antigo.localId)) {
        _removeSyncedItem(antigo.localId);
      }
    }

    for (final item in novos) {
      _syncItem(item.localId, item.toRascunhoItem());
    }

    setState(() {
      _orcamentoItems
        ..clear()
        ..addAll(novos);
    });
  }

  String? _modeloVeiculoCache;

  /// Marca/modelo do veículo da vistoria, pra escolher a tabela de preço.
  Future<String> _modeloVeiculo() async {
    final cached = _modeloVeiculoCache;
    if (cached != null) return cached;

    try {
      final modelo = await VistoriaChatSessionService.instance
          .loadVeiculoDaVistoria(widget.vistoriaDocId);
      return _modeloVeiculoCache = modelo;
    } catch (_) {
      return '';
    }
  }

  bool get _orcamentoPrecisaRevisao =>
      _orcamentoItems.any((item) => item.precisaRevisao);

  bool get _canSubmit =>
      !_orcamentoPrecisaRevisao &&
      (_photos.isNotEmpty ||
          _audios.isNotEmpty ||
          _textController.text.trim().isNotEmpty ||
          _orcamentoItems.isNotEmpty);

  /// Pede confirmação com o resumo do pacote antes de finalizar: o envio
  /// manda a vistoria para análise e não pode ser desfeito.
  Future<void> _submit() async {
    final confirmado = await showDialog<bool>(
      context: context,
      builder: (_) => _ConfirmarEnvioDialog(
        fotos: _photos.length,
        audios: _audios.length,
        temObservacoes: _textController.text.trim().isNotEmpty,
        itensOrcamento: _orcamentoItems.length,
        totalOrcamento: _orcamentoItems.fold<double>(
          0,
          (sum, item) => sum + item.valorTotal,
        ),
      ),
    );

    if (confirmado != true || !mounted) return;

    Navigator.of(context).pop(
      BulkUploadResult(
        photos: _photos,
        audios: _audios,
        text: _textController.text.trim(),
        orcamentoItems: _orcamentoItems,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: DraggableScrollableSheet(
        initialChildSize: 0.75,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        expand: false,
        builder: (context, scrollController) {
          return Container(
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
            ),
            child: Column(
              children: [
                const SizedBox(height: 12),
                Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(.15),
                    borderRadius: BorderRadius.circular(99),
                  ),
                ),
                const SizedBox(height: 16),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Enviar tudo de uma vez',
                      style: GoogleFonts.spaceGrotesk(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: const Color(0xFF1F2937),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 20),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Fotos, áudios, texto e orçamento — sem conversa passo a passo. '
                      'Até $kBulkMaxPhotos fotos e $kBulkMaxAudios áudios.',
                      style: TextStyle(
                        color: Color(0xFF6B7280),
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: ListView(
                    controller: scrollController,
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
                    children: [
                      _SectionLabel('Fotos (${_photos.length}/$kBulkMaxPhotos)'),
                      const SizedBox(height: 8),
                      _PhotoGrid(
                        photos: _photos,
                        canAddMore: _photos.length < kBulkMaxPhotos,
                        onAdd: _addPhotos,
                        onRemove: (i) async {
                          if (!await _confirmarRemocao('esta foto')) return;
                          final removed = _photos[i];
                          _removeSyncedItem(removed.localId);
                          setState(() => _photos.removeAt(i));
                        },
                      ),
                      const SizedBox(height: 20),
                      _SectionLabel('Áudios (${_audios.length}/$kBulkMaxAudios)'),
                      const SizedBox(height: 8),
                      _AudioList(
                        audios: _audios,
                        isRecording: _isRecording,
                        recordingSeconds: _recordingSeconds,
                        canRecordMore: _audios.length < kBulkMaxAudios,
                        onToggleRecording: _toggleRecording,
                        onRemove: (i) async {
                          if (!await _confirmarRemocao('este áudio')) return;
                          final removed = _audios[i];
                          _removeSyncedItem(removed.localId);
                          setState(() => _audios.removeAt(i));
                        },
                      ),
                      const SizedBox(height: 20),
                      const _SectionLabel('Observações'),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _textController,
                        maxLines: 4,
                        decoration: InputDecoration(
                          hintText: 'Descreva o que achar relevante...',
                          filled: true,
                          fillColor: const Color(0xFFF3FBFF),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(16),
                            borderSide: BorderSide.none,
                          ),
                        ),
                        onChanged: _onTextChanged,
                      ),
                      const SizedBox(height: 20),
                      const _SectionLabel('Orçamento'),
                      const SizedBox(height: 8),
                      _OrcamentoResumo(
                        items: _orcamentoItems,
                        precisaRevisao: _orcamentoPrecisaRevisao,
                        onEdit: _editOrcamento,
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                  child: SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: ElevatedButton.icon(
                      onPressed: _canSubmit ? _submit : null,
                      icon: const Icon(Icons.send_rounded),
                      label: const Text(
                        'Enviar',
                        style: TextStyle(fontWeight: FontWeight.w800),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF0057C0),
                        foregroundColor: Colors.white,
                        disabledBackgroundColor: Colors.black12,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(18),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Rótulo de seção (ex.: "Fotos", "Áudios") dentro do modal.
class _SectionLabel extends StatelessWidget {
  final String text;

  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        color: Color(0xFF1F2937),
        fontWeight: FontWeight.w800,
        fontSize: 13,
      ),
    );
  }
}

/// Grade com as fotos já tiradas e um botão pra adicionar mais.
class _PhotoGrid extends StatelessWidget {
  final List<BulkPhotoItem> photos;
  final bool canAddMore;
  final VoidCallback onAdd;
  final void Function(int index) onRemove;

  const _PhotoGrid({
    required this.photos,
    required this.canAddMore,
    required this.onAdd,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        for (var i = 0; i < photos.length; i++)
          Stack(
            clipBehavior: Clip.none,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: Image.file(
                  File(photos[i].path),
                  width: 78,
                  height: 78,
                  fit: BoxFit.cover,
                ),
              ),
              Positioned(
                top: -6,
                right: -6,
                child: IconButton(
                  tooltip: 'Remover foto',
                  icon: const Icon(
                    Icons.cancel_rounded,
                    color: Colors.redAccent,
                    size: 20,
                  ),
                  onPressed: () => onRemove(i),
                ),
              ),
            ],
          ),
        if (canAddMore)
          InkWell(
            onTap: onAdd,
            borderRadius: BorderRadius.circular(14),
            child: Container(
              width: 78,
              height: 78,
              decoration: BoxDecoration(
                color: const Color(0xFFF3FBFF),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: const Color(0xFF0057C0), width: 1.4),
              ),
              child: const Icon(
                Icons.add_a_photo_rounded,
                color: Color(0xFF0057C0),
              ),
            ),
          ),
      ],
    );
  }
}

/// Lista dos áudios já gravados, com botão de gravar mais um.
class _AudioList extends StatelessWidget {
  final List<BulkAudioItem> audios;
  final bool isRecording;
  final int recordingSeconds;
  final bool canRecordMore;
  final VoidCallback onToggleRecording;
  final void Function(int index) onRemove;

  const _AudioList({
    required this.audios,
    required this.isRecording,
    required this.recordingSeconds,
    required this.canRecordMore,
    required this.onToggleRecording,
    required this.onRemove,
  });

  String _formatDuration(int seconds) {
    final m = (seconds ~/ 60).toString().padLeft(2, '0');
    final s = (seconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < audios.length; i++)
          _BulkAudioPlayerTile(
            key: ValueKey(audios[i].localId),
            audio: audios[i],
            onRemove: () => onRemove(i),
          ),
        if (canRecordMore || isRecording)
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: onToggleRecording,
              icon: Icon(
                isRecording ? Icons.stop_circle_rounded : Icons.mic_rounded,
                color: isRecording ? Colors.redAccent : const Color(0xFF0057C0),
              ),
              label: Text(
                isRecording
                    ? 'Gravando... ${_formatDuration(recordingSeconds)}'
                    : 'Gravar áudio',
              ),
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFF0057C0),
                side: const BorderSide(color: Color(0xFF0057C0)),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Tile com player (play/pause + barra de progresso) de um áudio já gravado no pacote.
class _BulkAudioPlayerTile extends StatefulWidget {
  final BulkAudioItem audio;
  final VoidCallback onRemove;

  const _BulkAudioPlayerTile({
    super.key,
    required this.audio,
    required this.onRemove,
  });

  @override
  State<_BulkAudioPlayerTile> createState() => _BulkAudioPlayerTileState();
}

/// Estado do player: controla playback, posição e duração do áudio local.
class _BulkAudioPlayerTileState extends State<_BulkAudioPlayerTile> {
  final AudioPlayer _player = AudioPlayer();

  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<void>? _completeSubscription;

  bool _isPlaying = false;
  Duration _position = Duration.zero;
  late Duration _total = Duration(seconds: widget.audio.durationSeconds);

  @override
  void initState() {
    super.initState();

    _positionSubscription = _player.onPositionChanged.listen((position) {
      if (!mounted) return;
      setState(() => _position = position);
    });

    _completeSubscription = _player.onPlayerComplete.listen((_) {
      if (!mounted) return;
      setState(() {
        _isPlaying = false;
        _position = Duration.zero;
      });
    });
  }

  @override
  void dispose() {
    _positionSubscription?.cancel();
    _completeSubscription?.cancel();
    _player.dispose();
    super.dispose();
  }

  /// Alterna entre tocar e pausar o áudio local.
  Future<void> _togglePlay() async {
    try {
      if (_isPlaying) {
        await _player.pause();
        if (!mounted) return;
        setState(() => _isPlaying = false);
        return;
      }

      await _player.play(DeviceFileSource(widget.audio.path));

      if (!mounted) return;
      setState(() => _isPlaying = true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _isPlaying = false);
    }
  }

  String _formatDuration(Duration duration) {
    final m = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final total = _total.inMilliseconds > 0
        ? _total
        : Duration(seconds: widget.audio.durationSeconds);
    final progress = total.inMilliseconds == 0
        ? 0.0
        : (_position.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0);

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFF3FBFF),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          IconButton(
            onPressed: _togglePlay,
            tooltip: _isPlaying ? 'Pausar áudio' : 'Ouvir áudio',
            icon: Icon(
              _isPlaying
                  ? Icons.pause_circle_filled_rounded
                  : Icons.play_circle_fill_rounded,
              color: const Color(0xFF0057C0),
              size: 30,
            ),
          ),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(99),
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 4,
                backgroundColor: const Color(0xFF0057C0).withOpacity(.15),
                color: const Color(0xFF0057C0),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Text(
            _formatDuration(_isPlaying || _position > Duration.zero
                ? _position
                : total),
            style: const TextStyle(
              color: Color(0xFF6B7280),
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
          IconButton(
            tooltip: 'Remover áudio',
            icon: const Icon(Icons.delete_outline_rounded, size: 20),
            onPressed: widget.onRemove,
          ),
        ],
      ),
    );
  }
}

/// Resumo do orçamento do pacote; o detalhe é editado na tabela completa.
class _OrcamentoResumo extends StatelessWidget {
  final List<BulkOrcamentoItem> items;
  final bool precisaRevisao;
  final VoidCallback onEdit;

  const _OrcamentoResumo({
    required this.items,
    required this.precisaRevisao,
    required this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    final total = items.fold<double>(0, (sum, item) => sum + item.valorTotal);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (items.isNotEmpty)
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: const Color(0xFFF3FBFF),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final item in items)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            item.peca,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ),
                        Text(
                          item.precisaRevisao
                              ? 'Revisar'
                              : formatCurrencyBRL(item.valorTotal),
                          style: TextStyle(
                            color: item.precisaRevisao
                                ? const Color(0xFFB45309)
                                : const Color(0xFF6B7280),
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                const Divider(height: 16),
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Total',
                        style: TextStyle(fontWeight: FontWeight.w800),
                      ),
                    ),
                    Text(
                      formatCurrencyBRL(total),
                      style: const TextStyle(
                        color: Color(0xFF0057C0),
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        if (precisaRevisao)
          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: Text(
              'Alguns itens precisam ser revisados antes do envio.',
              style: TextStyle(
                color: Color(0xFFB45309),
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        OutlinedButton.icon(
          onPressed: onEdit,
          icon: Icon(items.isEmpty ? Icons.add_rounded : Icons.edit_rounded),
          label: Text(items.isEmpty ? 'Montar orçamento' : 'Editar orçamento'),
          style: OutlinedButton.styleFrom(
            foregroundColor: const Color(0xFF0057C0),
            side: const BorderSide(color: Color(0xFF0057C0)),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
          ),
        ),
      ],
    );
  }
}

/// Confirmação final do envio em massa, com o resumo do que vai ser enviado
/// e avisos do que está faltando (sem fotos, sem orçamento).
class _ConfirmarEnvioDialog extends StatelessWidget {
  final int fotos;
  final int audios;
  final bool temObservacoes;
  final int itensOrcamento;
  final double totalOrcamento;

  const _ConfirmarEnvioDialog({
    required this.fotos,
    required this.audios,
    required this.temObservacoes,
    required this.itensOrcamento,
    required this.totalOrcamento,
  });

  @override
  Widget build(BuildContext context) {
    final avisos = <String>[
      if (fotos == 0) 'Nenhuma foto foi adicionada.',
      if (itensOrcamento == 0) 'Nenhum item de orçamento foi adicionado.',
    ];

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 24),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Finalizar vistoria?',
              style: GoogleFonts.spaceGrotesk(
                fontSize: 17,
                fontWeight: FontWeight.bold,
                color: const Color(0xFF1F2937),
              ),
            ),
            const SizedBox(height: 14),
            _ResumoLinha(label: 'Fotos', value: '$fotos'),
            _ResumoLinha(label: 'Áudios', value: '$audios'),
            _ResumoLinha(
              label: 'Observações',
              value: temObservacoes ? 'Sim' : 'Não',
            ),
            _ResumoLinha(
              label: 'Orçamento',
              value: itensOrcamento == 0
                  ? '-'
                  : '$itensOrcamento ite${itensOrcamento > 1 ? 'ns' : 'm'} • '
                      '${formatCurrencyBRL(totalOrcamento)}',
            ),
            for (final aviso in avisos)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(
                      Icons.warning_amber_rounded,
                      color: Color(0xFFB45309),
                      size: 18,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        aviso,
                        style: const TextStyle(
                          color: Color(0xFF92400E),
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 14),
            const Text(
              'Depois do envio, a vistoria vai para análise e não poderá '
              'ser alterada.',
              style: TextStyle(color: Color(0xFF6B7280), fontSize: 12),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: TextButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    child: const Text('Revisar'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF0057C0),
                      foregroundColor: Colors.white,
                    ),
                    onPressed: () => Navigator.of(context).pop(true),
                    child: const Text('Enviar'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ResumoLinha extends StatelessWidget {
  final String label;
  final String value;

  const _ResumoLinha({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(color: Color(0xFF6B7280), fontSize: 13),
            ),
          ),
          Text(
            value,
            style: const TextStyle(
              color: Color(0xFF1F2937),
              fontSize: 13,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}
