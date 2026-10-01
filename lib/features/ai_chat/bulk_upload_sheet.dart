import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../../services/vistoria_chat_session_service.dart';
import '../camera/camera_page.dart';

const int kBulkMaxPhotos = 10;
const int kBulkMaxAudios = 10;

/// Chave fixa do item de texto livre no rascunho -- só existe um por vez,
/// diferente de foto/áudio/orçamento (que são listas), então não precisa de
/// um `localId` gerado a cada mudança.
const String kBulkTextRascunhoKey = '__texto__';

String _newLocalId() =>
    'bulk_${DateTime.now().microsecondsSinceEpoch}';

class BulkOrcamentoItem {
  final String localId;
  final String peca;
  final String tipoIntervencao;
  final double valorPeca;
  final double horasMaoObra;

  const BulkOrcamentoItem({
    required this.localId,
    required this.peca,
    required this.tipoIntervencao,
    required this.valorPeca,
    required this.horasMaoObra,
  });

  Map<String, dynamic> toRascunhoItem() => {
        'tipo': 'orcamento',
        'status': 'rascunho',
        'peca': peca,
        'tipoIntervencao': tipoIntervencao,
        'valorPeca': valorPeca,
        'horasMaoObra': horasMaoObra,
      };

  static BulkOrcamentoItem? fromRascunho(String localId, Map data) {
    return BulkOrcamentoItem(
      localId: localId,
      peca: (data['peca'] ?? '').toString(),
      tipoIntervencao: (data['tipoIntervencao'] ?? '').toString(),
      valorPeca: (data['valorPeca'] is num)
          ? (data['valorPeca'] as num).toDouble()
          : double.tryParse('${data['valorPeca']}') ?? 0,
      horasMaoObra: (data['horasMaoObra'] is num)
          ? (data['horasMaoObra'] as num).toDouble()
          : double.tryParse('${data['horasMaoObra']}') ?? 0,
    );
  }
}

/// Foto já copiada pro documents dir (persistente) -- diferente do path que
/// a `CameraPage`/`camera` devolve, que vive no diretório TEMPORÁRIO do
/// plugin e pode ser limpo pelo SO a qualquer momento. Sem essa cópia, uma
/// foto sobrevivia ao Firestore lembrar dela mas não ao arquivo em si.
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

/// Converte um rascunho persistido (`envioEmMassaRascunho`) num
/// `BulkUploadResult` pronto pra (re)enviar -- usado tanto pra pré-popular o
/// `BulkUploadSheet` quanto pela retomada automática quando a conexão volta
/// (`ai_chat_page.dart:_handleConnectivityRestored`), sem duplicar o parsing
/// nos dois lugares. Itens já `status: 'enviado'` são ignorados (já
/// confirmados, não reenvia). `onMissingFile`, se passado, é chamado uma vez
/// por item cujo arquivo local não existe mais (ex: usuário limpou dados do
/// app entre uma tentativa e outra).
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

/// Modal de composição do modo "enviar tudo de uma vez" -- reaproveita a
/// mesma `CameraPage` do fluxo guiado pra capturar fotos e o mesmo
/// `RecordConfig` (aacLc/128kbps/44.1kHz mono) pra áudio, só que sem
/// notificar o agente a cada item. Devolve tudo junto pro AiChatPage
/// orquestrar o upload quando o mecânico tocar "Enviar".
///
/// Cada item é espelhado no rascunho persistido do Firestore
/// (`envioEmMassaRascunho`) assim que entra/sai da lista -- é o que
/// sobrevive o app fechar/morrer no meio da montagem (ver
/// `VistoriaChatSessionService.upsertEnvioEmMassaRascunhoItem`).
class BulkUploadSheet extends StatefulWidget {
  final String vistoriaDocId;

  /// Itens que sobreviveram de uma tentativa anterior interrompida (lidos
  /// de `envioEmMassaRascunho` antes de abrir o modal). Itens já
  /// `status: 'enviado'` não aparecem aqui de propósito -- já foram
  /// confirmados, reabrir o modal não deve deixar reenviar/duplicar.
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

  void _syncItem(String localId, Map<String, dynamic> item) {
    unawaited(
      VistoriaChatSessionService.instance.upsertEnvioEmMassaRascunhoItem(
        vistoriaDocId: widget.vistoriaDocId,
        localId: localId,
        item: item,
      ),
    );
  }

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

    // Copia pro documents dir (persistente) -- o path que a CameraPage
    // devolve é do diretório temporário do plugin `camera`, que o SO pode
    // limpar a qualquer momento, inclusive antes do mecânico voltar pra
    // terminar o envio.
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

  Future<void> _toggleRecording() async {
    if (_isRecording) {
      await _stopRecording();
      return;
    }

    if (_audios.length >= kBulkMaxAudios) return;

    final hasPermission = await _recorder.hasPermission();

    if (!hasPermission) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Permissão de microfone necessária.')),
      );
      return;
    }

    final directory = await getApplicationDocumentsDirectory();
    final audioDirectory = Directory('${directory.path}/argos_audios');

    if (!await audioDirectory.exists()) {
      await audioDirectory.create(recursive: true);
    }

    final path =
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

  Future<void> _addOrcamentoItem() async {
    final item = await _showOrcamentoItemDialog();

    if (item == null || !mounted) return;

    _syncItem(item.localId, item.toRascunhoItem());

    setState(() => _orcamentoItems.add(item));
  }

  Future<BulkOrcamentoItem?> _showOrcamentoItemDialog() {
    final pecaController = TextEditingController();
    final tipoController = TextEditingController();
    final valorController = TextEditingController();
    final horasController = TextEditingController();

    return showDialog<BulkOrcamentoItem>(
      context: context,
      builder: (dialogContext) {
        return Dialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(28),
          ),
          insetPadding: const EdgeInsets.symmetric(horizontal: 24),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Item de orçamento',
                  style: GoogleFonts.spaceGrotesk(
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                    color: const Color(0xFF1F2937),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: pecaController,
                  decoration: const InputDecoration(labelText: 'Peça'),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: tipoController,
                  decoration: const InputDecoration(
                    labelText: 'Tipo de intervenção',
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: valorController,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'Valor da peça (R\$)',
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: horasController,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'Horas de mão de obra',
                  ),
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    Expanded(
                      child: TextButton(
                        onPressed: () => Navigator.of(dialogContext).pop(),
                        child: const Text('Cancelar'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF0057C0),
                          foregroundColor: Colors.white,
                        ),
                        onPressed: () {
                          final peca = pecaController.text.trim();
                          if (peca.isEmpty) return;

                          Navigator.of(dialogContext).pop(
                            BulkOrcamentoItem(
                              localId: _newLocalId(),
                              peca: peca,
                              tipoIntervencao: tipoController.text.trim(),
                              valorPeca: double.tryParse(
                                    valorController.text.replaceAll(',', '.'),
                                  ) ??
                                  0,
                              horasMaoObra: double.tryParse(
                                    horasController.text.replaceAll(',', '.'),
                                  ) ??
                                  0,
                            ),
                          );
                        },
                        child: const Text('Adicionar'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  bool get _canSubmit =>
      _photos.isNotEmpty ||
      _audios.isNotEmpty ||
      _textController.text.trim().isNotEmpty ||
      _orcamentoItems.isNotEmpty;

  void _submit() {
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
                        onRemove: (i) {
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
                        onRemove: (i) {
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
                      _OrcamentoList(
                        items: _orcamentoItems,
                        onAdd: _addOrcamentoItem,
                        onRemove: (i) {
                          final removed = _orcamentoItems[i];
                          _removeSyncedItem(removed.localId);
                          setState(() => _orcamentoItems.removeAt(i));
                        },
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

/// Player de verdade (play/pause + progresso) pra cada áudio já gravado no
/// pacote -- antes disso era só um rótulo estático com a duração, sem jeito
/// de ouvir de volta antes de mandar. Mesmo padrão de `AudioPlayer` já usado
/// em `ai_chat_page.dart` (`_AudioBubbleState`), tocando direto do arquivo
/// local (`DeviceFileSource`) já que nada aqui foi upado ainda.
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
            icon: const Icon(Icons.delete_outline_rounded, size: 20),
            onPressed: widget.onRemove,
          ),
        ],
      ),
    );
  }
}

class _OrcamentoList extends StatelessWidget {
  final List<BulkOrcamentoItem> items;
  final VoidCallback onAdd;
  final void Function(int index) onRemove;

  const _OrcamentoList({
    required this.items,
    required this.onAdd,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < items.length; i++)
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: const Color(0xFFF3FBFF),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        items[i].peca,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      Text(
                        '${items[i].tipoIntervencao} • R\$${items[i].valorPeca.toStringAsFixed(2)} • ${items[i].horasMaoObra}h',
                        style: const TextStyle(
                          color: Color(0xFF6B7280),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline_rounded, size: 20),
                  onPressed: () => onRemove(i),
                ),
              ],
            ),
          ),
        OutlinedButton.icon(
          onPressed: onAdd,
          icon: const Icon(Icons.add_rounded),
          label: const Text('Adicionar item'),
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
