// Testes do rascunho do envio em massa (lib/features/ai_chat/bulk_upload_sheet.dart):
// conversão entre `envioEmMassaRascunho` (Firestore) e os itens do modal.
// Os ramos de foto/áudio dependem de arquivos reais no disco e ficam de fora,
// exceto o caso de arquivo ausente (que não precisa de arquivo).
import 'package:argos_app/features/ai_chat/bulk_upload_sheet.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('BulkOrcamentoItem', () {
    test('fromRascunho remove tipo/status e força o id = localId', () {
      final item = BulkOrcamentoItem.fromRascunho('orc_local', {
        'id': 'outro_id',
        'tipo': 'orcamento',
        'status': 'rascunho',
        'peca': 'Para-lama',
        'valorTotal': 420.0,
      });

      expect(item, isNotNull);
      expect(item!.localId, 'orc_local');
      expect(item.dados['id'], 'orc_local');
      expect(item.dados.containsKey('tipo'), isFalse);
      expect(item.dados.containsKey('status'), isFalse);
      expect(item.peca, 'Para-lama');
      expect(item.valorTotal, 420.0);
    });

    test('fromRascunho descarta item sem peça', () {
      expect(BulkOrcamentoItem.fromRascunho('a', {'peca': ''}), isNull);
      expect(BulkOrcamentoItem.fromRascunho('b', {'peca': '   '}), isNull);
      expect(BulkOrcamentoItem.fromRascunho('c', {'valorTotal': 10}), isNull);
    });

    test('fromRascunho aceita mapa com chaves não-String', () {
      final item = BulkOrcamentoItem.fromRascunho('x', <dynamic, dynamic>{
        'peca': 'Grade',
        'valorTotal': 1,
      });
      expect(item?.peca, 'Grade');
    });

    test('precisaRevisao só quando falta valorTotal numérico (rascunho legado)', () {
      const comTotal = BulkOrcamentoItem(
        localId: 'a',
        dados: {'peca': 'Farol', 'valorTotal': 0},
      );
      const semTotal = BulkOrcamentoItem(
        localId: 'b',
        dados: {'peca': 'Farol'},
      );
      const totalEmTexto = BulkOrcamentoItem(
        localId: 'c',
        dados: {'peca': 'Farol', 'valorTotal': '100'},
      );

      expect(comTotal.precisaRevisao, isFalse);
      expect(semTotal.precisaRevisao, isTrue);
      expect(semTotal.valorTotal, 0);
      expect(totalEmTexto.precisaRevisao, isTrue);
    });

    test('toRascunhoItem marca tipo/status e mantém os dados', () {
      const item = BulkOrcamentoItem(
        localId: 'orc_9',
        dados: {'peca': 'Porta', 'valorHora': 130, 'valorTotal': 500},
      );

      expect(item.toRascunhoItem(), {
        'peca': 'Porta',
        'valorHora': 130,
        'valorTotal': 500,
        'id': 'orc_9',
        'tipo': 'orcamento',
        'status': 'rascunho',
      });
    });

    test('ida e volta toRascunhoItem -> fromRascunho', () {
      const original = BulkOrcamentoItem(
        localId: 'orc_7',
        dados: {'id': 'orc_7', 'peca': 'Capô', 'valorTotal': 900},
      );

      final copia =
          BulkOrcamentoItem.fromRascunho('orc_7', original.toRascunhoItem())!;

      expect(copia.localId, original.localId);
      expect(copia.dados, original.dados);
    });
  });

  group('buildBulkUploadResultFromRascunho', () {
    test('monta itens de orçamento e texto, ignorando enviados e inválidos', () {
      final result = buildBulkUploadResultFromRascunho({
        'orc_1': {
          'tipo': 'orcamento',
          'status': 'rascunho',
          'peca': 'Para-choque',
          'valorTotal': 700,
        },
        'orc_2': {
          'tipo': 'orcamento',
          'status': 'enviado', // já foi: não reenvia
          'peca': 'Farol',
          'valorTotal': 300,
        },
        'orc_3': {
          'tipo': 'orcamento',
          'status': 'rascunho',
          'peca': '', // sem peça: descartado
        },
        kBulkTextRascunhoKey: {
          'tipo': 'texto',
          'status': 'rascunho',
          'text': 'Batida na lateral esquerda',
        },
        'lixo': 'não é um mapa',
        'desconhecido': {'tipo': 'video', 'status': 'rascunho'},
      });

      expect(result.photos, isEmpty);
      expect(result.audios, isEmpty);
      expect(result.text, 'Batida na lateral esquerda');
      expect(result.orcamentoItems, hasLength(1));
      expect(result.orcamentoItems.single.localId, 'orc_1');
      expect(result.orcamentoItems.single.peca, 'Para-choque');
    });

    test('texto já enviado não volta para o modal', () {
      final result = buildBulkUploadResultFromRascunho({
        kBulkTextRascunhoKey: {
          'tipo': 'texto',
          'status': 'enviado',
          'text': 'antigo',
        },
      });

      expect(result.text, isEmpty);
    });

    test('rascunho vazio gera resultado vazio', () {
      final result = buildBulkUploadResultFromRascunho({});

      expect(result.photos, isEmpty);
      expect(result.audios, isEmpty);
      expect(result.text, isEmpty);
      expect(result.orcamentoItems, isEmpty);
    });

    test('foto/áudio sem arquivo no disco disparam onMissingFile', () {
      final faltando = <String>[];

      final result = buildBulkUploadResultFromRascunho(
        {
          'f1': {'tipo': 'foto', 'status': 'rascunho', 'localPath': ''},
          'a1': {
            'tipo': 'audio',
            'status': 'rascunho',
            'localPath': '/caminho/que/nao/existe.m4a',
          },
        },
        onMissingFile: faltando.add,
      );

      expect(result.photos, isEmpty);
      expect(result.audios, isEmpty);
      expect(faltando, unorderedEquals(['foto', 'áudio']));
    });
  });
}
