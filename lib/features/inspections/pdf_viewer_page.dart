import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:syncfusion_flutter_pdfviewer/pdfviewer.dart';

/// Tela genérica de leitura de PDF (orçamento aprovado, laudo técnico, etc.)
/// — mesma ideia do visualizador que já existe no web-argos
/// (components/orquestracao/pdf-viewer.tsx), só que nativo.
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

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
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
