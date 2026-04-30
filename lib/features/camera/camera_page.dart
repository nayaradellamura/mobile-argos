import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class CameraPage extends StatefulWidget {
  const CameraPage({super.key});

  @override
  State<CameraPage> createState() => _CameraPageState();
}

class _CameraPageState extends State<CameraPage> with WidgetsBindingObserver {
  CameraController? _controller;
  List<CameraDescription> _cameras = [];

  int _selectedCameraIndex = 0;

  bool _isInitializing = true;
  bool _isTakingPicture = false;

  XFile? _capturedImage;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initializeCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _disposeCamera();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted) return;

    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      _disposeCamera();
    }

    if (state == AppLifecycleState.resumed && _capturedImage == null) {
      _initializeCamera(_selectedCameraIndex);
    }
  }

  Future<void> _disposeCamera() async {
    final controller = _controller;
    _controller = null;

    if (controller != null) {
      await controller.dispose();
    }
  }

  Future<void> _initializeCamera([int cameraIndex = 0]) async {
    if (!mounted) return;

    setState(() {
      _isInitializing = true;
    });

    try {
      _cameras = await availableCameras();

      if (_cameras.isEmpty) {
        throw Exception('Nenhuma câmera encontrada no dispositivo.');
      }

      _selectedCameraIndex = cameraIndex.clamp(0, _cameras.length - 1);

      await _disposeCamera();

      final controller = CameraController(
        _cameras[_selectedCameraIndex],
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );

      _controller = controller;

      await controller.initialize();

      if (!mounted) return;

      setState(() {
        _isInitializing = false;
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _isInitializing = false;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Erro ao inicializar câmera: $e'),
          backgroundColor: Colors.redAccent,
        ),
      );
    }
  }

  Future<void> _takePicture() async {
    final controller = _controller;

    if (controller == null ||
        !controller.value.isInitialized ||
        _isTakingPicture) {
      return;
    }

    setState(() {
      _isTakingPicture = true;
    });

    try {
      final image = await controller.takePicture();

      if (!mounted) return;

      setState(() {
        _capturedImage = image;
      });

      await _disposeCamera();
    } catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Erro ao capturar foto: $e'),
          backgroundColor: Colors.redAccent,
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isTakingPicture = false;
        });
      }
    }
  }

  Future<void> _switchCamera() async {
    if (_cameras.length < 2 || _isInitializing || _capturedImage != null) {
      return;
    }

    final nextIndex = (_selectedCameraIndex + 1) % _cameras.length;

    await _initializeCamera(nextIndex);
  }

  Future<void> _retakePhoto() async {
    setState(() {
      _capturedImage = null;
    });

    await _initializeCamera(_selectedCameraIndex);
  }

  void _usePhoto() {
    if (_capturedImage == null) return;

    Navigator.of(context).pop<XFile>(_capturedImage);
  }

  Future<void> _closePage() async {
    await _disposeCamera();

    if (!mounted) return;

    Navigator.of(context).pop<XFile?>(null);
  }

  Widget _buildPreview() {
    final capturedImage = _capturedImage;
    final controller = _controller;

    if (capturedImage != null) {
      return Image.file(
        File(capturedImage.path),
        width: double.infinity,
        height: double.infinity,
        fit: BoxFit.cover,
      );
    }

    if (_isInitializing || controller == null) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white),
      );
    }

    if (!controller.value.isInitialized ||
        controller.value.previewSize == null) {
      return const Center(
        child: Text(
          'Câmera não inicializada',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
        ),
      );
    }

    final previewSize = controller.value.previewSize!;

    return ClipRect(
      child: FittedBox(
        fit: BoxFit.cover,
        child: SizedBox(
          width: previewSize.height,
          height: previewSize.width,
          child: CameraPreview(controller),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hasCapturedImage = _capturedImage != null;

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(child: _buildPreview()),

            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        Colors.black.withOpacity(.55),
                        Colors.transparent,
                        Colors.black.withOpacity(.75),
                      ],
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                    ),
                  ),
                ),
              ),
            ),

            Positioned(
              top: 18,
              left: 18,
              right: 18,
              child: Row(
                children: [
                  IconButton(
                    onPressed: _closePage,
                    style: IconButton.styleFrom(
                      backgroundColor: Colors.black.withOpacity(.45),
                      foregroundColor: Colors.white,
                    ),
                    icon: const Icon(Icons.close),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Captura de Evidência',
                      style: GoogleFonts.spaceGrotesk(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: hasCapturedImage ? null : _switchCamera,
                    style: IconButton.styleFrom(
                      backgroundColor: Colors.black.withOpacity(.45),
                      foregroundColor: Colors.white,
                      disabledForegroundColor: Colors.white38,
                    ),
                    icon: const Icon(Icons.cameraswitch),
                  ),
                ],
              ),
            ),

            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 28),
                child: AspectRatio(
                  aspectRatio: .72,
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(32),
                      border: Border.all(
                        color: Colors.white.withOpacity(.35),
                        width: 2,
                      ),
                    ),
                    child: Stack(
                      children: const [
                        _CornerGuide(
                          alignment: Alignment.topLeft,
                          top: true,
                          left: true,
                        ),
                        _CornerGuide(
                          alignment: Alignment.topRight,
                          top: true,
                          right: true,
                        ),
                        _CornerGuide(
                          alignment: Alignment.bottomLeft,
                          bottom: true,
                          left: true,
                        ),
                        _CornerGuide(
                          alignment: Alignment.bottomRight,
                          bottom: true,
                          right: true,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),

            Positioned(
              top: 88,
              left: 24,
              right: 24,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(.45),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: Colors.white.withOpacity(.08)),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.remove_red_eye,
                      color: Color(0xFFE5F6FF),
                      size: 18,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        hasCapturedImage
                            ? 'Foto capturada. Confira antes de anexar.'
                            : 'Posicione o dano dentro do quadro.',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            Positioned(
              left: 24,
              right: 24,
              bottom: 28,
              child: Column(
                children: [
                  if (hasCapturedImage)
                    SizedBox(
                      width: double.infinity,
                      height: 56,
                      child: ElevatedButton.icon(
                        onPressed: _usePhoto,
                        icon: const Icon(Icons.check_circle),
                        label: const Text('Usar esta foto na vistoria'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF0057C0),
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(20),
                          ),
                        ),
                      ),
                    ),

                  if (hasCapturedImage) const SizedBox(height: 14),

                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      _CameraOptionButton(
                        icon: hasCapturedImage
                            ? Icons.refresh
                            : Icons.photo_library_outlined,
                        label: hasCapturedImage ? 'Refazer' : 'Galeria',
                        onTap: hasCapturedImage ? _retakePhoto : null,
                      ),

                      GestureDetector(
                        onTap: hasCapturedImage ? null : _takePicture,
                        child: AnimatedOpacity(
                          duration: const Duration(milliseconds: 180),
                          opacity: hasCapturedImage ? .35 : 1,
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 180),
                            width: 84,
                            height: 84,
                            padding: const EdgeInsets.all(6),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: Colors.white.withOpacity(.78),
                                width: 4,
                              ),
                            ),
                            child: Container(
                              decoration: const BoxDecoration(
                                color: Colors.white,
                                shape: BoxShape.circle,
                              ),
                              child: _isTakingPicture
                                  ? const Center(
                                      child: CircularProgressIndicator(
                                        color: Color(0xFF0057C0),
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : null,
                            ),
                          ),
                        ),
                      ),

                      _CameraOptionButton(
                        icon: Icons.cameraswitch,
                        label: 'Virar',
                        onTap: hasCapturedImage ? null : _switchCamera,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CornerGuide extends StatelessWidget {
  final Alignment alignment;
  final bool top;
  final bool bottom;
  final bool left;
  final bool right;

  const _CornerGuide({
    required this.alignment,
    this.top = false,
    this.bottom = false,
    this.left = false,
    this.right = false,
  });

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: alignment,
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          border: Border(
            top: top
                ? const BorderSide(color: Color(0xFFE5F6FF), width: 4)
                : BorderSide.none,
            bottom: bottom
                ? const BorderSide(color: Color(0xFFE5F6FF), width: 4)
                : BorderSide.none,
            left: left
                ? const BorderSide(color: Color(0xFFE5F6FF), width: 4)
                : BorderSide.none,
            right: right
                ? const BorderSide(color: Color(0xFFE5F6FF), width: 4)
                : BorderSide.none,
          ),
        ),
      ),
    );
  }
}

class _CameraOptionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  const _CameraOptionButton({
    required this.icon,
    required this.label,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;

    return GestureDetector(
      onTap: onTap,
      child: Opacity(
        opacity: enabled ? 1 : .35,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 54,
              height: 54,
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(.45),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: Colors.white.withOpacity(.14)),
              ),
              child: Icon(icon, color: Colors.white),
            ),
            const SizedBox(height: 7),
            Text(
              label.toUpperCase(),
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 9,
                fontWeight: FontWeight.w900,
                letterSpacing: .8,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
