import 'package:cloud_firestore/cloud_firestore.dart';
import '../../orcamento/orcamento_calculo.dart';
import 'package:flutter/material.dart';

import 'inspection_parsing_utils.dart';

// Preview de um áudio anexado à vistoria (rótulo + referência pra tocar).
class AudioPreviewInfo {
  final String label;
  final String storagePath;
  final String downloadUrl;

  const AudioPreviewInfo({
    required this.label,
    this.storagePath = '',
    this.downloadUrl = '',
  });

  bool get canPlay => storagePath.trim().isNotEmpty || downloadUrl.trim().isNotEmpty;
}

// Tipo de conteúdo de uma mensagem de chat no preview do histórico.
enum ChatPreviewKind { text, image, audio }

// Preview resumido de uma mensagem do chat da vistoria.
class ChatPreviewInfo {
  final String role;
  final String text;
  final ChatPreviewKind kind;

  const ChatPreviewInfo({
    required this.role,
    required this.text,
    this.kind = ChatPreviewKind.text,
  });
}

// Item de orçamento da vistoria (peça + intervenção + valores).
class OrcamentoRascunhoItem {
  final String peca;
  final String tipoIntervencao;
  final int quantidade;
  final double valorPeca;
  final String tipoServico;
  final double horasMaoObra;
  final double valorHora;

  // 'vistoria' (montado pelo ADK), 'sugestao_aceita' (sugestão da IA aceita)
  // ou 'mecanico' (envio em massa).
  final String origem;

  const OrcamentoRascunhoItem({
    required this.peca,
    required this.tipoIntervencao,
    required this.quantidade,
    required this.valorPeca,
    required this.tipoServico,
    required this.horasMaoObra,
    required this.valorHora,
    required this.origem,
  });

  double get valorTotal => valorTotalItem(
        valorPeca: valorPeca,
        quantidade: quantidade,
        horasMaoObra: horasMaoObra,
        valorHora: valorHora,
      );

  bool get isDoMecanico => origem == 'mecanico';
}

// Modelo de uma vistoria vinculada a um sinistro, com dados e previews pro
// histórico/resumo.
class LinkedVistoriaInfo {
  final String docId;
  final String idvistoria;
  final String sinistroId;
  final String status;
  final int chatCount;
  final int imageCount;
  final int audioCount;
  final bool hasLaudo;
  final List<String> imageBase64Previews;
  final List<AudioPreviewInfo> audioPreviews;
  final List<ChatPreviewInfo> chatPreviews;
  final String laudo;
  final String pdfLaudoUrl;
  final String observacoes;
  final String placa;
  final String veiculo;
  final String cliente;
  final String credenciado;
  final String tipoVistoria;
  final String inspectorId;
  final String inspectorName;
  final String inspectorEmail;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  // 'em_massa' | 'guiado' | '' (vistorias de antes desse campo existir).
  final String coletaModo;
  final List<OrcamentoRascunhoItem> orcamentoItems;

  const LinkedVistoriaInfo({
    required this.docId,
    required this.idvistoria,
    required this.sinistroId,
    required this.status,
    required this.chatCount,
    required this.imageCount,
    required this.audioCount,
    required this.hasLaudo,
    required this.imageBase64Previews,
    required this.audioPreviews,
    required this.chatPreviews,
    required this.laudo,
    this.pdfLaudoUrl = '',
    required this.observacoes,
    required this.placa,
    required this.veiculo,
    required this.cliente,
    required this.credenciado,
    required this.tipoVistoria,
    required this.inspectorId,
    required this.inspectorName,
    required this.inspectorEmail,
    required this.createdAt,
    required this.updatedAt,
    this.coletaModo = '',
    this.orcamentoItems = const [],
  });

  // Constrói a partir de um documento de vistoria do Firestore.
  factory LinkedVistoriaInfo.fromFirestore(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = doc.data() ?? <String, dynamic>{};

    final images = data['images'] is List ? data['images'] as List : const [];
    final audios = data['audios'] is List ? data['audios'] as List : const [];
    final chatmessages =
        data['chatmessages'] is List ? data['chatmessages'] as List : const [];

    final lastAudioNumber = data['lastAudioNumber'] is int
        ? data['lastAudioNumber'] as int
        : int.tryParse('${data['lastAudioNumber']}') ?? 0;

    final extractedAudioPreviewList = _extractAudioPreviews(audios);
    final audioPreviewList = extractedAudioPreviewList.isNotEmpty
        ? extractedAudioPreviewList
        : List<AudioPreviewInfo>.generate(
            lastAudioNumber > 6 ? 6 : lastAudioNumber,
            (index) => AudioPreviewInfo(label: 'Áudio ${index + 1}'),
          );
    final resolvedAudioCount = audios.length > lastAudioNumber
        ? audios.length
        : lastAudioNumber;

    final laudo = stringValue(data['laudo']);
    final pdfLaudoUrl = stringValue(data['pdfLaudoUrl']);

    return LinkedVistoriaInfo(
      docId: doc.id,
      idvistoria: stringValue(data['idvistoria'], fallback: doc.id),
      sinistroId: stringValue(data['sinistroId']),
      status: stringValue(data['status'], fallback: 'em_andamento'),
      chatCount: chatmessages.length,
      imageCount: images.length,
      audioCount: resolvedAudioCount,
      hasLaudo: laudo.isNotEmpty || pdfLaudoUrl.isNotEmpty,
      imageBase64Previews: _extractImageBase64Previews(images),
      audioPreviews: audioPreviewList,
      chatPreviews: _extractChatPreviews(chatmessages),
      laudo: laudo,
      pdfLaudoUrl: pdfLaudoUrl,
      observacoes: stringValue(data['observacoes']),
      placa: stringValue(data['placa']),
      veiculo: stringValue(data['veiculo']),
      cliente: stringValue(data['cliente']),
      credenciado: stringValue(data['credenciado']),
      tipoVistoria: stringValue(data['tipoVistoria'], fallback: 'ORIGINAL'),
      inspectorId: stringValue(data['inspectorId']),
      inspectorName: stringValue(
        data['inspectorName'],
        fallback: stringValue(
          data['inspectorNome'],
          fallback: stringValue(data['inspectorEmail']),
        ),
      ),
      inspectorEmail: stringValue(data['inspectorEmail']),
      createdAt: parseFirestoreDateTime(data['createdAt']),
      updatedAt: parseFirestoreDateTime(data['updatedAt']),
      coletaModo: stringValue(data['coletaModo']),
      orcamentoItems: _extractOrcamentoItems(data),
    );
  }

  bool get isEmMassa => coletaModo == 'em_massa';

  // True se o tipoVistoria indica uma retificação/revisão.
  bool get isRetificacao {
    final normalized = normalizeStatusText(tipoVistoria);

    return normalized.contains('retificacao') ||
        normalized.contains('retificação') ||
        normalized.contains('revisao') ||
        normalized.contains('revisão');
  }

  String get tipoLabel => isRetificacao ? 'Retificação' : 'Original';

  String get responsibleLabel {
    final name = inspectorName.trim();
    final email = inspectorEmail.trim();

    if (name.isNotEmpty) return name;
    if (email.isNotEmpty) return email;
    return 'Mecânico não informado';
  }

  // Texto do status da vistoria pro histórico/resumo.
  String get statusLabel {
    final normalized = normalizeStatusText(status);

    if (normalized.contains('abandonada') ||
        normalized.contains('abandonado')) return 'Abandonada';
    if (normalized.contains('expirada') ||
        normalized.contains('expirado')) return 'Expirada';
    if (normalized.contains('cancelada') ||
        normalized.contains('cancelado')) return 'Cancelada';
    if (normalized.contains('rejeitada') ||
        normalized.contains('rejeitado')) return 'Rejeitada';
    if (normalized.contains('encerrada') ||
        normalized.contains('encerrado')) return 'Encerrada';
    if (normalized.contains('aprovada') ||
        normalized.contains('aprovado') ||
        normalized.contains('approved') ||
        normalized.contains('finalizada') ||
        normalized.contains('finalizado') ||
        normalized.contains('finalized')) return 'Finalizada';
    if (normalized.contains('analise') || normalized.contains('análise')) {
      return 'Em análise';
    }

    return 'Em andamento';
  }

  // Cor correspondente ao status da vistoria (espelha statusLabel).
  Color get statusColor {
    final normalized = normalizeStatusText(status);

    if (normalized.contains('abandonada') ||
        normalized.contains('abandonado')) return Colors.grey;
    if (normalized.contains('expirada') ||
        normalized.contains('expirado')) return Colors.deepOrange;
    if (normalized.contains('cancelada') ||
        normalized.contains('cancelado')) return Colors.redAccent;
    if (normalized.contains('rejeitada') ||
        normalized.contains('rejeitado')) return Colors.redAccent;
    if (normalized.contains('encerrada') ||
        normalized.contains('encerrado')) return Colors.green;
    if (normalized.contains('analise') ||
        normalized.contains('análise') ||
        normalized.contains('finalizada') ||
        normalized.contains('finalizado') ||
        normalized.contains('finalized')) return Colors.purple;

    return const Color(0xFF0057C0);
  }

  // Ícone correspondente ao status da vistoria (espelha statusLabel).
  IconData get statusIcon {
    final normalized = normalizeStatusText(status);

    if (normalized.contains('abandonada') ||
        normalized.contains('abandonado')) return Icons.block_outlined;
    if (normalized.contains('expirada') ||
        normalized.contains('expirado')) return Icons.timer_off_outlined;
    if (normalized.contains('cancelada') ||
        normalized.contains('cancelado')) return Icons.cancel_outlined;
    if (normalized.contains('rejeitada') ||
        normalized.contains('rejeitado')) return Icons.rate_review_outlined;
    if (normalized.contains('encerrada') ||
        normalized.contains('encerrado')) return Icons.task_alt_outlined;
    if (normalized.contains('analise') ||
        normalized.contains('análise') ||
        normalized.contains('finalizada') ||
        normalized.contains('finalizado') ||
        normalized.contains('finalized')) {
      return Icons.manage_search_outlined;
    }

    return Icons.pending_actions_outlined;
  }
}

// Extrai URLs/base64 de preview das imagens da vistoria.
List<String> _extractImageBase64Previews(List<dynamic> images) {
  final previews = <String>[];

  for (final item in images) {
    if (item is String && item.trim().isNotEmpty) {
      previews.add(item.trim());
      continue;
    }

    if (item is Map) {
      final directImage = stringValue(
        item['url'],
        fallback: stringValue(
          item['downloadUrl'],
          fallback: stringValue(
            item['imageUrl'],
            fallback: stringValue(item['imagePath']),
          ),
        ),
      );

      if (directImage.isNotEmpty) {
        previews.add(directImage);
        continue;
      }

      for (final entry in item.entries) {
        final key = entry.key.toString();
        final value = entry.value;

        if (key.startsWith('vistoria_') &&
            value is String &&
            value.trim().isNotEmpty) {
          previews.add(value.trim());
          break;
        }
      }
    }
  }

  return previews;
}

// Itens de orçamento da vistoria. No fluxo guiado, a lista confirmada pelo
// mecânico fica em `orcamentoItensFinais` (o `orcamentoRascunho` é só o
// pré-preenchimento do agente); no envio em massa, em `orcamentoRascunho`.
List<OrcamentoRascunhoItem> _extractOrcamentoItems(Map<String, dynamic> data) {
  final finais = data['orcamentoItensFinais'];
  final rascunho = data['orcamentoRascunho'];
  final raw = (finais is List && finais.isNotEmpty)
      ? finais
      : rascunho;

  double toDouble(dynamic value) => value is num
      ? value.toDouble()
      : parseValorDecimal('${value ?? ''}') ?? 0;

  // Orçamento fechado só na conversa: o agente grava em
  // agentParameters.itens_orcamento (snake_case), sem tabela nem rascunho.
  if (raw is! List || raw.isEmpty) {
    final params = data['agentParameters'];
    final doAgente = params is Map ? params['itens_orcamento'] : null;
    if (doAgente is! List) return const [];

    return doAgente.whereType<Map>().map((item) {
      final quantidade = toDouble(item['quantidade']).round();

      return OrcamentoRascunhoItem(
        peca: stringValue(item['peca']),
        tipoIntervencao: stringValue(item['tipo_intervencao']),
        quantidade: quantidade < 1 ? 1 : quantidade,
        valorPeca: toDouble(item['valor_peca']),
        tipoServico: stringValue(item['tipo_servico']),
        horasMaoObra: toDouble(item['horas_mao_obra']),
        valorHora: item['valor_hora'] == null
            ? kValorHoraLegado
            : toDouble(item['valor_hora']),
        origem: 'vistoria',
      );
    }).where((item) => item.peca.isNotEmpty).toList();
  }

  return raw.whereType<Map>().map((item) {
    final quantidade = toDouble(item['quantidade']).round();

    return OrcamentoRascunhoItem(
      peca: stringValue(item['peca']),
      tipoIntervencao: stringValue(item['tipoIntervencao']),
      quantidade: quantidade < 1 ? 1 : quantidade,
      valorPeca: toDouble(item['valorPeca']),
      tipoServico: stringValue(item['tipoServico']),
      horasMaoObra: toDouble(item['horasMaoObra']),
      valorHora: item['valorHora'] == null
          ? kValorHoraLegado
          : toDouble(item['valorHora']),
      origem: stringValue(item['origem'], fallback: 'vistoria'),
    );
  }).toList();
}

// Monta os previews de áudio, escolhendo o melhor rótulo disponível por item.
List<AudioPreviewInfo> _extractAudioPreviews(List<dynamic> audios) {
  final previews = <AudioPreviewInfo>[];

  for (var index = 0; index < audios.length; index++) {
    final item = audios[index];
    String label = 'Áudio ${index + 1}';
    String storagePath = '';
    String downloadUrl = '';

    if (item is Map) {
      final audioId = stringValue(item['audioId']);
      final fileName = stringValue(item['fileName']);
      storagePath = stringValue(item['storagePath']);
      downloadUrl = stringValue(
        item['mp3DownloadUrl'],
        fallback: stringValue(
          item['downloadUrl'],
          fallback: stringValue(
            item['audioUrl'],
            fallback: stringValue(item['url']),
          ),
        ),
      );
      final sizeBytes = item['sizeBytes'];

      if (audioId.isNotEmpty) {
        label = audioId;
      } else if (fileName.isNotEmpty) {
        label = fileName;
      } else if (storagePath.isNotEmpty) {
        label = storagePath.split('/').last.replaceAll('.mp3', '');
      } else if (sizeBytes is num && sizeBytes > 0) {
        label = 'Áudio ${index + 1} • ${formatFileSize(sizeBytes.toInt())}';
      }
    }

    previews.add(
      AudioPreviewInfo(
        label: label,
        storagePath: storagePath,
        downloadUrl: downloadUrl,
      ),
    );
  }

  return previews;
}

// Monta os previews do chat, classificando cada mensagem em texto/imagem/áudio.
List<ChatPreviewInfo> _extractChatPreviews(List<dynamic> messages) {
  final previews = <ChatPreviewInfo>[];
  final source = messages.length > 1 ? messages.skip(1) : messages;

  for (final item in source) {
    if (item is String && item.trim().isNotEmpty) {
      previews.add(
        ChatPreviewInfo(
          role: 'user',
          text: item.trim(),
        ),
      );
      continue;
    }

    if (item is Map) {
      final role = stringValue(
        item['role'],
        fallback: stringValue(item['sender'], fallback: 'user'),
      );

      final rawType = stringValue(item['type']).toLowerCase();
      final hasAudio = rawType.contains('audio') ||
          stringValue(item['audioPath']).isNotEmpty ||
          stringValue(item['audioId']).isNotEmpty ||
          stringValue(item['mp3DownloadUrl']).isNotEmpty ||
          stringValue(item['storagePath']).toLowerCase().contains('/audio/');
      final hasImage = rawType.contains('image') ||
          rawType.contains('foto') ||
          stringValue(item['imagePath']).isNotEmpty ||
          stringValue(item['imageUrl']).isNotEmpty;

      if (hasAudio) {
        previews.add(
          ChatPreviewInfo(
            role: role,
            text: 'Áudio enviado',
            kind: ChatPreviewKind.audio,
          ),
        );
        continue;
      }

      if (hasImage) {
        previews.add(
          ChatPreviewInfo(
            role: role,
            text: 'Foto enviada',
            kind: ChatPreviewKind.image,
          ),
        );
        continue;
      }

      final text = stringValue(
        item['text'],
        fallback: stringValue(
          item['message'],
          fallback: stringValue(item['originalText']),
        ),
      );

      if (text.trim().isEmpty) continue;

      previews.add(
        ChatPreviewInfo(
          role: role,
          text: text.trim(),
        ),
      );
    }
  }

  return previews;
}
