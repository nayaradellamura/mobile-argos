import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/painting.dart';

import 'inspection_case.dart';

/// Aquece a query de vistorias e as fotos de perfil da equipe durante a
/// splash de abertura do app, pra tela de Vistorias abrir com tudo já em
/// cache.
class InspectionsPrefetchService {
  InspectionsPrefetchService._();

  static final InspectionsPrefetchService instance =
      InspectionsPrefetchService._();

  final Set<String> _precachedUrls = <String>{};

  /// Busca os sinistros do credenciado e precacheia as fotos de perfil
  /// envolvidas.
  Future<void> warmUp(String credenciadoId) async {
    if (credenciadoId.trim().isEmpty) return;

    try {
      final snapshot = await FirebaseFirestore.instance
          .collection('sinistro')
          .where('credenciadoId', isEqualTo: credenciadoId)
          .get();

      final inspections =
          snapshot.docs.map(InspectionCase.fromFirestore).toList();

      _precacheAvatarUrls(inspections);
    } catch (_) {}
  }

  /// Coleta as URLs de foto de perfil únicas e dispara o precache de cada uma.
  void _precacheAvatarUrls(List<InspectionCase> inspections) {
    final urls = <String>{};

    for (final inspection in inspections) {
      final assignedPhoto = inspection.assignedToPhotoURL.trim();

      if (assignedPhoto.isNotEmpty) {
        urls.add(assignedPhoto);
      }

      for (final viewer in inspection.activeViewers) {
        final viewerPhoto = viewer.photoURL.trim();

        if (viewerPhoto.isNotEmpty) {
          urls.add(viewerPhoto);
        }
      }
    }

    for (final url in urls) {
      if (!_precachedUrls.add(url)) continue;
      _precacheNetworkImage(url);
    }
  }

  /// Equivalente ao `precacheImage()` do Flutter, mas sem depender de um
  /// `BuildContext` montado.
  void _precacheNetworkImage(String url) {
    final stream = NetworkImage(url).resolve(ImageConfiguration.empty);

    late ImageStreamListener listener;
    listener = ImageStreamListener(
      (image, synchronousCall) => stream.removeListener(listener),
      onError: (error, stackTrace) => stream.removeListener(listener),
    );

    stream.addListener(listener);
  }
}
