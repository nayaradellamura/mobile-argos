import 'package:cloud_firestore/cloud_firestore.dart';

/// Helpers de parsing de dados vindos do Firestore, usados por todos os
/// modelos da feature de vistorias (e por alguns widgets que ainda leem
/// campos de forma pontual, como o preview de histórico de áudios).

Map<String, dynamic> asStringMap(dynamic value) {
  if (value is Map<String, dynamic>) {
    return value;
  }

  if (value is Map) {
    return value.map((key, item) => MapEntry(key.toString(), item));
  }

  return <String, dynamic>{};
}

String stringValue(dynamic value, {String fallback = ''}) {
  if (value == null) return fallback;

  final text = value.toString().trim();

  if (text.isEmpty) return fallback;

  return text;
}

DateTime? parseFirestoreDateTime(dynamic value) {
  if (value == null) return null;

  if (value is Timestamp) {
    return value.toDate();
  }

  if (value is DateTime) {
    return value;
  }

  final text = value.toString().trim();

  if (text.isEmpty || text.toLowerCase() == 'null') {
    return null;
  }

  return DateTime.tryParse(text);
}

/// Normaliza status/tipo (minúsculas, sem acento, sem `_`/`-`) para permitir
/// comparações por substring resilientes a variações de grafia vindas do
/// backend.
String normalizeStatusText(dynamic value) {
  return stringValue(value)
      .toLowerCase()
      .replaceAll('_', ' ')
      .replaceAll('-', ' ')
      .replaceAll('ã', 'a')
      .replaceAll('á', 'a')
      .replaceAll('à', 'a')
      .replaceAll('â', 'a')
      .replaceAll('é', 'e')
      .replaceAll('ê', 'e')
      .replaceAll('í', 'i')
      .replaceAll('ó', 'o')
      .replaceAll('ô', 'o')
      .replaceAll('õ', 'o')
      .replaceAll('ú', 'u')
      .replaceAll('ç', 'c')
      .trim();
}

String formatFileSize(int bytes) {
  if (bytes < 1024) return '$bytes B';

  final kb = bytes / 1024;
  if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';

  final mb = kb / 1024;
  return '${mb.toStringAsFixed(1)} MB';
}
