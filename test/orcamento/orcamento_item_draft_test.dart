// Testes da conversão Firestore <-> OrcamentoItemDraft
// (lib/features/orcamento/orcamento_table_page.dart). O shape do mapa é o
// contrato entre o app, o agente ADK e o laudo-service.
import 'package:argos_app/features/orcamento/orcamento_calculo.dart';
import 'package:argos_app/features/orcamento/orcamento_table_page.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('OrcamentoItemDraft.fromMap', () {
    test('lê um item completo do rascunho do agente', () {
      final item = OrcamentoItemDraft.fromMap({
        'id': 'orc_1',
        'peca': 'Para-choque dianteiro',
        'tipoIntervencao': 'reparo',
        'quantidade': 2,
        'valorPeca': 850.0,
        'tipoServico': 'pintura',
        'horasMaoObra': 3.5,
        'origem': 'mecanico',
      });

      expect(item.id, 'orc_1');
      expect(item.peca, 'Para-choque dianteiro');
      expect(item.tipoIntervencao, 'reparo');
      expect(item.quantidade, 2);
      expect(item.valorPeca, 850.0);
      expect(item.tipoServico, 'pintura');
      expect(item.horasMaoObra, 3.5);
      expect(item.origem, 'mecanico');
    });

    test('tipoServico desconhecido ou ausente cai no padrão', () {
      final desconhecido = OrcamentoItemDraft.fromMap({
        'peca': 'Farol',
        'tipoServico': 'tapecaria',
      });
      final ausente = OrcamentoItemDraft.fromMap({'peca': 'Farol'});

      expect(desconhecido.tipoServico, kTipoServicoPadrao);
      expect(ausente.tipoServico, kTipoServicoPadrao);
    });

    test('valores ausentes recebem defaults seguros', () {
      final item = OrcamentoItemDraft.fromMap({'peca': 'Retrovisor'});

      expect(item.id, isNotEmpty); // gera id local
      expect(item.tipoIntervencao, 'substituicao');
      expect(item.quantidade, 1);
      expect(item.valorPeca, 0);
      expect(item.horasMaoObra, 0);
      expect(item.origem, 'vistoria');
    });

    test('id vazio gera um novo id', () {
      final item = OrcamentoItemDraft.fromMap({'id': '', 'peca': 'Capô'});
      expect(item.id, startsWith('orc_'));
    });

    test('quantidade 0, negativa ou inválida vira 1', () {
      for (final q in [0, -3, 'abc', null]) {
        final item = OrcamentoItemDraft.fromMap({'peca': 'X', 'quantidade': q});
        expect(item.quantidade, 1, reason: 'quantidade=$q');
      }
    });

    test('números em texto no formato brasileiro são convertidos', () {
      final item = OrcamentoItemDraft.fromMap({
        'peca': 'Porta',
        'quantidade': '3',
        'valorPeca': '1.250,90',
        'horasMaoObra': '2,5',
      });

      expect(item.quantidade, 3);
      expect(item.valorPeca, closeTo(1250.90, 1e-9));
      expect(item.horasMaoObra, 2.5);
    });
  });

  group('OrcamentoItemDraft.toMap', () {
    test('congela o valorHora e calcula mão de obra e total', () {
      final item = OrcamentoItemDraft(
        id: 'orc_2',
        peca: '  Farol direito  ',
        quantidade: 2,
        valorPeca: 400,
        tipoServico: 'eletrica',
        horasMaoObra: 1.5,
      );

      final map = item.toMap(valorHora: 120);

      expect(map['id'], 'orc_2');
      expect(map['peca'], 'Farol direito'); // trim
      expect(map['tipoIntervencao'], 'substituicao');
      expect(map['quantidade'], 2);
      expect(map['valorPeca'], 400);
      expect(map['tipoServico'], 'eletrica');
      expect(map['horasMaoObra'], 1.5);
      expect(map['valorHora'], 120);
      expect(map['valorMaoObra'], 180);
      expect(map['valorTotal'], 400 * 2 + 180);
      expect(map['origem'], 'vistoria');
    });

    test('ida e volta (toMap -> fromMap) preserva os campos', () {
      final original = OrcamentoItemDraft(
        id: 'orc_3',
        peca: 'Capô',
        tipoIntervencao: 'reparo',
        quantidade: 1,
        valorPeca: 0,
        tipoServico: 'funilaria',
        horasMaoObra: 4,
        origem: 'mecanico',
      );

      final copia = OrcamentoItemDraft.fromMap(original.toMap(valorHora: 95));

      expect(copia.id, original.id);
      expect(copia.peca, original.peca);
      expect(copia.tipoIntervencao, original.tipoIntervencao);
      expect(copia.quantidade, original.quantidade);
      expect(copia.valorPeca, original.valorPeca);
      expect(copia.tipoServico, original.tipoServico);
      expect(copia.horasMaoObra, original.horasMaoObra);
      expect(copia.origem, original.origem);
    });

    test('o total gravado bate com somarItensOrcamento', () {
      final itens = [
        OrcamentoItemDraft(peca: 'A', valorPeca: 100, horasMaoObra: 1),
        OrcamentoItemDraft(peca: 'B', quantidade: 3, valorPeca: 50, horasMaoObra: 0.5),
      ].map((i) => i.toMap(valorHora: 110)).toList();

      final somaDosTotais =
          itens.fold<double>(0, (s, i) => s + (i['valorTotal'] as num));

      expect(somarItensOrcamento(itens), closeTo(somaDosTotais, 1e-9));
    });
      test('mão de obra em reais vira 1 h ao valor informado e volta igual', () {
      final original = OrcamentoItemDraft(
        peca: 'Pintura',
        valorPeca: 0,
        tipoServico: 'pintura',
        maoObraEmValor: true,
        valorMaoObra: 700,
        origem: 'arquivo',
      );

      // O valor da hora da oficina é ignorado para esse item.
      final map = original.toMap(valorHora: 90);

      expect(map['horasMaoObra'], 1);
      expect(map['valorHora'], 700);
      expect(map['valorMaoObra'], 700);
      expect(map['valorTotal'], 700);
      expect(map['maoObraEmValor'], isTrue);
      expect(somarItensOrcamento([map]), 700);

      final copia = OrcamentoItemDraft.fromMap(map);
      expect(copia.maoObraEmValor, isTrue);
      expect(copia.valorMaoObra, 700);
      expect(copia.horasMaoObra, 0);
    });

    test('item em horas não grava a marca de mão de obra em reais', () {
      final map = OrcamentoItemDraft(peca: 'X', horasMaoObra: 2).toMap(valorHora: 50);
      expect(map.containsKey('maoObraEmValor'), isFalse);
      expect(map['valorMaoObra'], 100);
    });
  });
}
