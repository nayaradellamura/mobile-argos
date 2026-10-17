// Testes das regras de cálculo e formatação do orçamento
// (lib/features/orcamento/orcamento_calculo.dart). São as mesmas regras do
// laudo-service e do agente ADK, então qualquer divergência aqui aparece
// como diferença de valor entre o app e o PDF do laudo.
import 'package:argos_app/features/orcamento/orcamento_calculo.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseValorDecimal', () {
    test('aceita formato brasileiro com milhar e centavos', () {
      expect(parseValorDecimal('1.234,56'), closeTo(1234.56, 1e-9));
    });

    test('aceita vírgula decimal sem separador de milhar', () {
      expect(parseValorDecimal('1234,56'), closeTo(1234.56, 1e-9));
    });

    test('aceita ponto decimal (formato americano)', () {
      expect(parseValorDecimal('1234.56'), closeTo(1234.56, 1e-9));
    });

    test('aceita vários separadores de milhar', () {
      expect(parseValorDecimal('1.234.567,89'), closeTo(1234567.89, 1e-6));
    });

    test('ignora espaços nas pontas', () {
      expect(parseValorDecimal('  10,5 '), 10.5);
    });

    test('campo vazio (ou só espaços) vale 0', () {
      expect(parseValorDecimal(''), 0);
      expect(parseValorDecimal('   '), 0);
    });

    test('texto inválido retorna null', () {
      expect(parseValorDecimal('abc'), isNull);
      expect(parseValorDecimal('12,3,4'), isNull);
    });

    test('valor negativo é rejeitado (null)', () {
      expect(parseValorDecimal('-5'), isNull);
      expect(parseValorDecimal('-1.234,56'), isNull);
    });

    test('sem vírgula, o ponto é tratado como decimal ("1.234" = 1,234)', () {
      // Comportamento documentado: só existe ambiguidade quando o usuário
      // digita milhar sem centavos. O teclado numérico do app usa vírgula.
      expect(parseValorDecimal('1.234'), closeTo(1.234, 1e-9));
    });
  });

  group('valorTotalItem', () {
    test('peça × quantidade + horas × valor da hora', () {
      expect(
        valorTotalItem(
          valorPeca: 350,
          quantidade: 2,
          horasMaoObra: 1.5,
          valorHora: 120,
        ),
        350 * 2 + 1.5 * 120,
      );
    });

    test('item só de mão de obra (peça zerada)', () {
      expect(
        valorTotalItem(
          valorPeca: 0,
          quantidade: 1,
          horasMaoObra: 3,
          valorHora: 90,
        ),
        270,
      );
    });

    test('item só de peça (sem horas)', () {
      expect(
        valorTotalItem(
          valorPeca: 199.9,
          quantidade: 3,
          horasMaoObra: 0,
          valorHora: 150,
        ),
        closeTo(599.7, 1e-9),
      );
    });
  });

  group('formatCurrencyBRL', () {
    test('zero', () {
      expect(formatCurrencyBRL(0), r'R$ 0,00');
    });

    test('milhar com centavos', () {
      expect(formatCurrencyBRL(1234.5), r'R$ 1.234,50');
    });

    test('milhão', () {
      expect(formatCurrencyBRL(1000000), r'R$ 1.000.000,00');
    });

    test('valores pequenos sem separador de milhar', () {
      expect(formatCurrencyBRL(999.99), r'R$ 999,99');
      expect(formatCurrencyBRL(12), r'R$ 12,00');
    });

    test('negativo leva o sinal depois do símbolo', () {
      expect(formatCurrencyBRL(-1234.5), r'R$ -1.234,50');
    });

    test('arredonda para 2 casas', () {
      expect(formatCurrencyBRL(10.005 + 0.001), r'R$ 10,01');
    });
  });

  group('formatHoras', () {
    test('horas inteiras sem casas decimais', () {
      expect(formatHoras(2), '2h');
      expect(formatHoras(0), '0h');
      expect(formatHoras(10), '10h');
    });

    test('horas fracionadas com vírgula e uma casa', () {
      expect(formatHoras(1.5), '1,5h');
      expect(formatHoras(0.5), '0,5h');
    });
  });

  group('formatDecimalInput', () {
    test('usa vírgula e casas fixas', () {
      expect(formatDecimalInput(1234.5), '1234,50');
      expect(formatDecimalInput(2, casas: 1), '2,0');
    });
  });

  group('tipoServicoLabel / tipoIntervencaoLabel', () {
    test('rótulos conhecidos e fallback', () {
      expect(tipoServicoLabel('mecanica'), 'Mecânica');
      expect(tipoServicoLabel('desconhecido'), 'desconhecido');
      expect(tipoIntervencaoLabel('reparo'), 'Reparo');
      expect(tipoIntervencaoLabel('substituicao'), 'Substituição');
      expect(tipoIntervencaoLabel(''), 'Substituição');
    });
  });

  group('somarItensOrcamento', () {
    test('lista vazia soma 0', () {
      expect(somarItensOrcamento(const []), 0);
    });

    test('usa o valorHora congelado em cada item', () {
      final total = somarItensOrcamento([
        {
          'valorPeca': 500,
          'quantidade': 1,
          'horasMaoObra': 2,
          'valorHora': 150,
        },
        {
          'valorPeca': 100,
          'quantidade': 4,
          'horasMaoObra': 1,
          'valorHora': 200,
        },
      ]);

      expect(total, (500 + 2 * 150) + (100 * 4 + 1 * 200));
    });

    test('item legado sem valorHora usa kValorHoraLegado (R\$ 90)', () {
      expect(kValorHoraLegado, 90.0);

      final total = somarItensOrcamento([
        {'valorPeca': 300, 'quantidade': 1, 'horasMaoObra': 2},
      ]);

      expect(total, 300 + 2 * kValorHoraLegado);
    });

    test('quantidade ausente ou 0 conta como 1', () {
      final semQuantidade = somarItensOrcamento([
        {'valorPeca': 250, 'horasMaoObra': 0, 'valorHora': 100},
      ]);
      final quantidadeZero = somarItensOrcamento([
        {'valorPeca': 250, 'quantidade': 0, 'horasMaoObra': 0, 'valorHora': 100},
      ]);

      expect(semQuantidade, 250);
      expect(quantidadeZero, 250);
    });

    test('aceita números gravados como texto (formato brasileiro)', () {
      final total = somarItensOrcamento([
        {
          'valorPeca': '1.000,50',
          'quantidade': '2',
          'horasMaoObra': '1,5',
          'valorHora': 100,
        },
      ]);

      expect(total, closeTo(1000.5 * 2 + 1.5 * 100, 1e-9));
    });

    test('campos inválidos viram 0 sem quebrar a soma', () {
      final total = somarItensOrcamento([
        {'valorPeca': 'abc', 'quantidade': 1, 'horasMaoObra': null, 'valorHora': 100},
        {'valorPeca': 50, 'quantidade': 1, 'horasMaoObra': 0, 'valorHora': 100},
      ]);

      expect(total, 50);
    });
  });

  group('nomeLegivel', () {
    test('nome todo em maiúsculas vira só a primeira maiúscula', () {
      expect(nomeLegivel('LAMPADA LANTERNA D'), 'Lampada lanterna d');
      expect(nomeLegivel('POLIMENTO FARÓIS'), 'Polimento faróis');
    });

    test('nome escrito normalmente e siglas curtas ficam como estão', () {
      expect(nomeLegivel('Fluido freio DOT 4'), 'Fluido freio DOT 4');
      expect(nomeLegivel('ABS'), 'ABS');
    });
  });
}
