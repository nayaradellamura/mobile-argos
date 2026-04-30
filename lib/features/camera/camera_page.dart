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
  static const int maxPhotos = 10;

  CameraController? _controller;
  List<CameraDescription> _cameras = [];

  int _selectedCameraIndex = 0;

  bool _isInitializing = true;
  bool _isTakingPicture = false;
  bool _isFlashOn = false;

  double _minZoom = 1.0;
  double _maxZoom = 1.0;
  double _currentZoom = 1.0;

  final List<XFile> _photos = [];

  List<int> get _backCameraIndexes {
    final indexes = <int>[];

    for (int i = 0; i < _cameras.length; i++) {
      if (_cameras[i].lensDirection == CameraLensDirection.back) {
        indexes.add(i);
      }
    }

    return indexes;
  }

  bool get _hasMultipleBackCameras => _backCameraIndexes.length > 1;

  bool get _canUseFlash {
    if (_cameras.isEmpty) return false;

    if (_selectedCameraIndex < 0 || _selectedCameraIndex >= _cameras.length) {
      return false;
    }

    return _cameras[_selectedCameraIndex].lensDirection ==
        CameraLensDirection.back;
  }

  bool get _canUseZoom {
    return (_maxZoom - _minZoom).abs() > .05;
  }

  int get _currentBackCameraNumber {
    final backIndexes = _backCameraIndexes;
    final position = backIndexes.indexOf(_selectedCameraIndex);

    if (position == -1) return 1;

    return position + 1;
  }

  String get _zoomLabel {
    final rounded = _currentZoom.roundToDouble();

    if ((_currentZoom - rounded).abs() < .05) {
      return '${rounded.toInt()}x';
    }

    return '${_currentZoom.toStringAsFixed(1)}x';
  }

  int get _preferredInitialCameraIndex {
    final firstBackCameraIndex = _cameras.indexWhere(
      (camera) => camera.lensDirection == CameraLensDirection.back,
    );

    if (firstBackCameraIndex != -1) {
      return firstBackCameraIndex;
    }

    return 0;
  }

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

    if (state == AppLifecycleState.resumed) {
      _initializeCamera(_selectedCameraIndex);
    }
  }

  double _clampZoom(double value) {
    if (value < _minZoom) return _minZoom;
    if (value > _maxZoom) return _maxZoom;
    return value;
  }

  Future<void> _disposeCamera() async {
    final controller = _controller;
    _controller = null;

    if (controller != null) {
      try {
        if (controller.value.isInitialized) {
          await controller.setFlashMode(FlashMode.off);
        }
      } catch (_) {}

      await controller.dispose();
    }
  }

  Future<void> _initializeCamera([int? cameraIndex]) async {
    if (!mounted) return;

    setState(() {
      _isInitializing = true;
      _isFlashOn = false;
      _currentZoom = 1.0;
    });

    try {
      _cameras = await availableCameras();

      final backIndexes = _backCameraIndexes;

      if (backIndexes.isEmpty) {
        throw Exception('Nenhuma câmera traseira encontrada no dispositivo.');
      }

      final targetIndex = cameraIndex ?? _preferredInitialCameraIndex;

      if (!backIndexes.contains(targetIndex)) {
        _selectedCameraIndex = backIndexes.first;
      } else {
        _selectedCameraIndex = targetIndex;
      }

      await _disposeCamera();

      final controller = CameraController(
        _cameras[_selectedCameraIndex],
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );

      _controller = controller;

      await controller.initialize();

      try {
        await controller.setFlashMode(FlashMode.off);
      } catch (_) {}

      try {
        _minZoom = await controller.getMinZoomLevel();
        _maxZoom = await controller.getMaxZoomLevel();

        _currentZoom = _clampZoom(1.0);

        await controller.setZoomLevel(_currentZoom);
      } catch (_) {
        _minZoom = 1.0;
        _maxZoom = 1.0;
        _currentZoom = 1.0;
      }

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

  Future<void> _toggleFlash() async {
    final controller = _controller;

    if (!_canUseFlash) return;

    if (controller == null || !controller.value.isInitialized) {
      return;
    }

    try {
      final nextFlashMode = _isFlashOn ? FlashMode.off : FlashMode.torch;

      await controller.setFlashMode(nextFlashMode);

      if (!mounted) return;

      setState(() {
        _isFlashOn = !_isFlashOn;
      });
    } catch (_) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Flash indisponível nesta câmera.'),
          backgroundColor: Colors.orange,
        ),
      );
    }
  }

  Future<void> _setZoom(double value) async {
    final controller = _controller;

    if (controller == null || !controller.value.isInitialized) return;

    final zoom = _clampZoom(value);

    try {
      await controller.setZoomLevel(zoom);

      if (!mounted) return;

      setState(() {
        _currentZoom = zoom;
      });
    } catch (_) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Não foi possível alterar o zoom.'),
          backgroundColor: Colors.orange,
        ),
      );
    }
  }

  Future<void> _resetZoom() async {
    await _setZoom(1.0);
  }

  Future<void> _takePicture() async {
    final controller = _controller;

    if (_photos.length >= maxPhotos) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Limite máximo de 10 fotos atingido.'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

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
        _photos.add(image);
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Foto ${_photos.length}/$maxPhotos capturada.'),
          backgroundColor: Colors.green,
          duration: const Duration(milliseconds: 900),
        ),
      );
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

  Future<void> _switchBackLens() async {
    if (!_hasMultipleBackCameras || _isInitializing) return;

    final backIndexes = _backCameraIndexes;
    final currentPosition = backIndexes.indexOf(_selectedCameraIndex);
    final safePosition = currentPosition == -1 ? 0 : currentPosition;
    final nextPosition = (safePosition + 1) % backIndexes.length;
    final nextCameraIndex = backIndexes[nextPosition];

    setState(() {
      _isFlashOn = false;
      _currentZoom = 1.0;
    });

    await _initializeCamera(nextCameraIndex);
  }

  Future<void> _closePage() async {
    await _disposeCamera();

    if (!mounted) return;

    Navigator.of(context).pop<List<XFile>?>(null);
  }

  void _finishCapture() {
    if (_photos.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Capture pelo menos 1 foto para continuar.'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    Navigator.of(context).pop<List<XFile>>(List<XFile>.from(_photos));
  }

  void _openPhotosManager() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (bottomSheetContext) {
        return StatefulBuilder(
          builder: (context, sheetSetState) {
            return Container(
              height: MediaQuery.of(context).size.height * .72,
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
              decoration: const BoxDecoration(
                color: Color(0xFFF3FBFF),
                borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
              ),
              child: Column(
                children: [
                  Container(
                    width: 46,
                    height: 5,
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(.16),
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Fotos capturadas',
                          style: GoogleFonts.spaceGrotesk(
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                            color: const Color(0xFF0057C0),
                          ),
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 7,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFFE5F6FF),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          '${_photos.length}/$maxPhotos',
                          style: const TextStyle(
                            color: Color(0xFF0057C0),
                            fontWeight: FontWeight.w900,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Toque em uma foto para visualizar. Use o botão vermelho para remover.',
                      style: TextStyle(
                        color: Color(0xFF414755),
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  Expanded(
                    child: _photos.isEmpty
                        ? const _EmptyPhotosState()
                        : GridView.builder(
                            itemCount: _photos.length,
                            gridDelegate:
                                const SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: 3,
                                  crossAxisSpacing: 12,
                                  mainAxisSpacing: 12,
                                  childAspectRatio: .78,
                                ),
                            itemBuilder: (context, index) {
                              final photo = _photos[index];

                              return _PhotoGridItem(
                                photo: photo,
                                index: index,
                                onTap: () {
                                  _openPhotoPreview(
                                    index,
                                    sheetSetState: sheetSetState,
                                  );
                                },
                                onDelete: () {
                                  setState(() {
                                    _photos.removeAt(index);
                                  });
                                  sheetSetState(() {});
                                },
                              );
                            },
                          ),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    height: 54,
                    child: ElevatedButton.icon(
                      onPressed: () {
                        Navigator.of(bottomSheetContext).pop();
                      },
                      icon: const Icon(Icons.check),
                      label: const Text('Concluir revisão'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF0057C0),
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(18),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  void _openPhotoPreview(int index, {StateSetter? sheetSetState}) {
    if (index < 0 || index >= _photos.length) return;

    showDialog<void>(
      context: context,
      barrierColor: Colors.black.withOpacity(.94),
      builder: (dialogContext) {
        final photo = _photos[index];

        return Dialog.fullscreen(
          backgroundColor: Colors.black,
          child: SafeArea(
            child: Stack(
              children: [
                Positioned.fill(
                  child: InteractiveViewer(
                    minScale: .8,
                    maxScale: 4,
                    child: Center(
                      child: Image.file(File(photo.path), fit: BoxFit.contain),
                    ),
                  ),
                ),
                Positioned(
                  top: 16,
                  left: 16,
                  child: IconButton(
                    onPressed: () {
                      Navigator.of(dialogContext).pop();
                    },
                    style: IconButton.styleFrom(
                      backgroundColor: Colors.white.withOpacity(.14),
                      foregroundColor: Colors.white,
                    ),
                    icon: const Icon(Icons.close),
                  ),
                ),
                Positioned(
                  top: 16,
                  right: 16,
                  child: IconButton(
                    onPressed: () {
                      Navigator.of(dialogContext).pop();

                      setState(() {
                        if (index >= 0 && index < _photos.length) {
                          _photos.removeAt(index);
                        }
                      });

                      sheetSetState?.call(() {});
                    },
                    style: IconButton.styleFrom(
                      backgroundColor: Colors.redAccent,
                      foregroundColor: Colors.white,
                    ),
                    icon: const Icon(Icons.delete_outline),
                  ),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 24,
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(.14),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        'Foto ${index + 1} de ${_photos.length}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildCameraPreview() {
    final controller = _controller;

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
    final photoCount = _photos.length;
    final reachedLimit = photoCount >= maxPhotos;
    final canFinish = photoCount >= 1;

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(child: _buildCameraPreview()),
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        Colors.black.withOpacity(.58),
                        Colors.transparent,
                        Colors.black.withOpacity(.86),
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
                      'Captura de Evidências',
                      style: GoogleFonts.spaceGrotesk(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: reachedLimit
                          ? Colors.orange.withOpacity(.88)
                          : Colors.black.withOpacity(.45),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: Colors.white.withOpacity(.12)),
                    ),
                    child: Text(
                      '$photoCount/$maxPhotos',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w900,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  if (_canUseFlash) ...[
                    const SizedBox(width: 10),
                    InkWell(
                      borderRadius: BorderRadius.circular(14),
                      onTap: _toggleFlash,
                      child: Container(
                        width: 42,
                        height: 42,
                        decoration: BoxDecoration(
                          color: _isFlashOn
                              ? const Color(0xFF0057C0).withOpacity(.92)
                              : Colors.black.withOpacity(.45),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: _isFlashOn
                                ? const Color(0xFFE5F6FF).withOpacity(.75)
                                : Colors.white.withOpacity(.12),
                          ),
                        ),
                        child: Icon(
                          _isFlashOn ? Icons.flash_on : Icons.flash_off,
                          color: Colors.white,
                          size: 21,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),

            Positioned(
              left: 24,
              right: 24,
              bottom: 28,
              child: Column(
                children: [
                  _ZoomControl(
                    enabled: _canUseZoom && !_isInitializing,
                    minZoom: _minZoom,
                    maxZoom: _maxZoom,
                    currentZoom: _currentZoom,
                    label: _zoomLabel,
                    onChanged: _setZoom,
                    onReset: _resetZoom,
                  ),
                  const SizedBox(height: 14),
                  SizedBox(
                    width: double.infinity,
                    height: 56,
                    child: ElevatedButton.icon(
                      onPressed: canFinish ? _finishCapture : null,
                      icon: const Icon(Icons.check_circle),
                      label: Text(
                        canFinish
                            ? 'Usar $photoCount foto${photoCount > 1 ? 's' : ''} na vistoria'
                            : 'Capture pelo menos 1 foto',
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF0057C0),
                        foregroundColor: Colors.white,
                        disabledBackgroundColor: Colors.white.withOpacity(.18),
                        disabledForegroundColor: Colors.white54,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(20),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      _CameraOptionButton(
                        icon: Icons.photo_library_outlined,
                        label: 'Ver fotos',
                        badge: photoCount > 0 ? '$photoCount' : null,
                        onTap: _openPhotosManager,
                      ),
                      GestureDetector(
                        onTap: reachedLimit ? null : _takePicture,
                        child: AnimatedOpacity(
                          duration: const Duration(milliseconds: 180),
                          opacity: reachedLimit ? .35 : 1,
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
                        icon: Icons.linked_camera,
                        label: 'Lente',
                        badge: _hasMultipleBackCameras
                            ? '$_currentBackCameraNumber/${_backCameraIndexes.length}'
                            : '1/1',
                        onTap: _hasMultipleBackCameras ? _switchBackLens : null,
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

class _ZoomControl extends StatelessWidget {
  final bool enabled;
  final double minZoom;
  final double maxZoom;
  final double currentZoom;
  final String label;
  final ValueChanged<double> onChanged;
  final VoidCallback onReset;

  const _ZoomControl({
    required this.enabled,
    required this.minZoom,
    required this.maxZoom,
    required this.currentZoom,
    required this.label,
    required this.onChanged,
    required this.onReset,
  });

  @override
  Widget build(BuildContext context) {
    final safeMin = minZoom;
    final safeMax = maxZoom <= minZoom ? minZoom + 0.1 : maxZoom;
    final safeValue = currentZoom.clamp(safeMin, safeMax).toDouble();

    return AnimatedOpacity(
      duration: const Duration(milliseconds: 180),
      opacity: enabled ? 1 : .55,
      child: Container(
        height: 58,
        padding: const EdgeInsets.fromLTRB(14, 7, 10, 7),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(.45),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.white.withOpacity(.12)),
        ),
        child: Row(
          children: [
            GestureDetector(
              onTap: enabled ? onReset : null,
              child: Container(
                width: 42,
                height: 42,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: const Color(0xFF0057C0).withOpacity(.80),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Text(
                  label,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            const Icon(Icons.zoom_out, color: Colors.white70, size: 18),
            Expanded(
              child: Slider(
                value: safeValue,
                min: safeMin,
                max: safeMax,
                onChanged: enabled ? onChanged : null,
              ),
            ),
            const Icon(Icons.zoom_in, color: Colors.white70, size: 18),
          ],
        ),
      ),
    );
  }
}

class _EmptyPhotosState extends StatelessWidget {
  const _EmptyPhotosState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: Colors.black.withOpacity(.05)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.photo_library_outlined,
              color: Color(0xFF0057C0),
              size: 42,
            ),
            const SizedBox(height: 12),
            Text(
              'Nenhuma foto ainda',
              style: GoogleFonts.spaceGrotesk(
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'Capture pelo menos uma evidência para continuar.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Color(0xFF414755)),
            ),
          ],
        ),
      ),
    );
  }
}

class _PhotoGridItem extends StatelessWidget {
  final XFile photo;
  final int index;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _PhotoGridItem({
    required this.photo,
    required this.index,
    required this.onTap,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: Colors.black.withOpacity(.06)),
                image: DecorationImage(
                  image: FileImage(File(photo.path)),
                  fit: BoxFit.cover,
                ),
              ),
            ),
          ),
          Positioned(
            left: 7,
            bottom: 7,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(.62),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                '${index + 1}',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 10,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
          ),
          Positioned(
            top: -8,
            right: -8,
            child: GestureDetector(
              onTap: onDelete,
              child: Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: Colors.redAccent,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 2),
                ),
                child: const Icon(Icons.close, color: Colors.white, size: 15),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CameraOptionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? badge;
  final VoidCallback? onTap;

  const _CameraOptionButton({
    required this.icon,
    required this.label,
    this.badge,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;

    return GestureDetector(
      onTap: onTap,
      child: Opacity(
        opacity: enabled ? 1 : .45,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Stack(
              clipBehavior: Clip.none,
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
                if (badge != null)
                  Positioned(
                    top: -6,
                    right: -6,
                    child: Container(
                      height: 24,
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      alignment: Alignment.center,
                      constraints: const BoxConstraints(minWidth: 24),
                      decoration: BoxDecoration(
                        color: const Color(0xFF0057C0),
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(color: Colors.white, width: 2),
                      ),
                      child: Text(
                        badge!,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                  ),
              ],
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
