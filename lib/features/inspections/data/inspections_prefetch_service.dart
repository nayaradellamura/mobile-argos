import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/painting.dart';

import 'inspection_case.dart';

/// Aquece a query de vistorias e as fotos de perfil da equipe durante a
/// splash de abertura do app — tempo que, de outra forma, ficaria ocioso
/// esperando a animação da splash terminar.
///
/// Quando o usuário chega na tela de Vistorias, o Firestore já tem essa
/// mesma query no cache local (então o primeiro snapshot chega quase
/// instantâneo) e as fotos de perfil já estão no ImageCache do Flutter —
/// os cards aparecem prontos, sem esperar o carregamento das fotos.
class InspectionsPrefetchService {
  InspectionsPrefetchService._();

  static final InspectionsPrefetchService instance =
      InspectionsPrefetchService._();

  final Set<String> _precachedUrls = <String>{};

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
    } catch (_) {
      // Melhor esforço: se falhar (sem rede, etc.), a tela de Vistorias
      // carrega tudo normalmente quando for aberta.
    }
  }

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

  // Equivalente ao precacheImage() do Flutter, mas sem depender de um
  // BuildContext montado — a splash roda antes de qualquer tela real
  // existir na árvore de widgets.
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
