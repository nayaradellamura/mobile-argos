import 'dart:io';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:syncfusion_flutter_pdfviewer/pdfviewer.dart';

/// Tela genérica de leitura de PDF (orçamento aprovado, laudo técnico, etc.)
/// — mesma ideia do visualizador que já existe no web-argos
/// (components/orquestracao/pdf-viewer.tsx), só que nativo, com baixar e
/// compartilhar direto no leitor.
class PdfViewerPage extends StatefulWidget {
  final String url;
  final String title;

  const PdfViewerPage({super.key, required this.url, required this.title});

  @override
  State<PdfViewerPage> createState() => _PdfViewerPageState();
}

class _PdfViewerPageState extends State<PdfViewerPage> {
  final PdfViewerController _controller = PdfViewerController();
  String? _erro;
  File? _arquivoLocal;
  bool _baixando = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String get _nomeArquivo {
    final limpo = widget.title.replaceAll(RegExp(r'[^\w\-]+'), '_').trim();
    return '${limpo.isEmpty ? 'documento' : limpo}.pdf';
  }

  /// Baixa o PDF uma vez só e guarda localmente — tanto "Baixar" quanto
  /// "Compartilhar" precisam do arquivo em disco (o leitor em si mostra
  /// direto da URL, sem precisar disso).
  Future<File> _garantirArquivoLocal() async {
    if (_arquivoLocal != null) return _arquivoLocal!;

    final resposta = await http.get(Uri.parse(widget.url));
    if (resposta.statusCode != 200) {
      throw Exception('Falha ao baixar o PDF (HTTP ${resposta.statusCode}).');
    }

    final dir = await getApplicationDocumentsDirectory();
    final arquivo = File('${dir.path}/$_nomeArquivo');
    await arquivo.writeAsBytes(resposta.bodyBytes, flush: true);

    _arquivoLocal = arquivo;
    return arquivo;
  }

  Future<void> _baixar() async {
    if (_baixando) return;
    setState(() => _baixando = true);
    try {
      final arquivo = await _garantirArquivoLocal();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('PDF salvo: ${arquivo.path}')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Não foi possível baixar o PDF: $e')),
      );
    } finally {
      if (mounted) setState(() => _baixando = false);
    }
  }

  Future<void> _compartilhar() async {
    if (_baixando) return;
    setState(() => _baixando = true);
    try {
      final arquivo = await _garantirArquivoLocal();
      if (!mounted) return;
      await SharePlus.instance.share(
        ShareParams(
          text: widget.title,
          files: [XFile(arquivo.path, mimeType: 'application/pdf')],
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Não foi possível compartilhar o PDF: $e')),
      );
    } finally {
      if (mounted) setState(() => _baixando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF3F5F8),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0057C0),
        foregroundColor: Colors.white,
        elevation: 0,
        title: Text(
          widget.title,
          style: GoogleFonts.spaceGrotesk(
            fontWeight: FontWeight.bold,
            fontSize: 16,
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'Diminuir zoom',
            icon: const Icon(Icons.zoom_out),
            onPressed: () {
              _controller.zoomLevel = (_controller.zoomLevel - 0.25).clamp(1, 3);
            },
          ),
          IconButton(
            tooltip: 'Aumentar zoom',
            icon: const Icon(Icons.zoom_in),
            onPressed: () {
              _controller.zoomLevel = (_controller.zoomLevel + 0.25).clamp(1, 3);
            },
          ),
          if (_baixando)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 14),
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
              ),
            )
          else ...[
            IconButton(
              tooltip: 'Baixar PDF',
              icon: const Icon(Icons.download_outlined),
              onPressed: _baixar,
            ),
            IconButton(
              tooltip: 'Compartilhar PDF',
              icon: const Icon(Icons.share_outlined),
              onPressed: _compartilhar,
            ),
          ],
        ],
      ),
      body: _erro != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.error_outline, size: 40, color: Colors.redAccent),
                    const SizedBox(height: 12),
                    Text(
                      'Não foi possível carregar o PDF.\n$_erro',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.black54),
                    ),
                  ],
                ),
              ),
            )
          : SfPdfViewer.network(
              widget.url,
              controller: _controller,
              canShowScrollHead: true,
              canShowScrollStatus: true,
              onDocumentLoadFailed: (details) {
                setState(() => _erro = details.description);
              },
            ),
    );
  }
}
