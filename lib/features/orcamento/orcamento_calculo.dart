/// Regras de cálculo e formatação do orçamento compartilhadas entre o fluxo
/// guiado (tabela liberada pelo agente) e o envio em massa.
///
/// O valor da hora de mão de obra NÃO é fixo: cada oficina configura o seu,
/// por tipo de serviço, em `credenciados/{id}.valoresHoraMaoObra` (ver
/// `ValoresHoraService`). No envio, cada item leva o valor usado
/// (`valorHora`), congelado — mudar a configuração depois não altera
/// orçamentos já enviados.

/// Tipos de serviço de mão de obra, cada um com seu valor de hora.
const Map<String, String> kTiposServico = {
  'funilaria': 'Funilaria',
  'pintura': 'Pintura',
  'mecanica': 'Mecânica',
  'eletrica': 'Elétrica',
};

const String kTipoServicoPadrao = 'funilaria';

/// Só para itens gravados antes do valor da hora configurável (sem
/// `valorHora`). Mesmo valor de `VALOR_HORA_LEGADO` no laudo-service e de
/// `_VALOR_HORA_LEGADO` no agente, para o histórico bater com o PDF.
const double kValorHoraLegado = 90.0;

String tipoServicoLabel(String tipo) => kTiposServico[tipo] ?? tipo;

/// Converte o texto digitado em número, aceitando "1.234,56", "1234,56" e
/// "1234.56". Campo vazio vale 0; texto inválido retorna null.
double? parseValorDecimal(String raw) {
  var text = raw.trim();
  if (text.isEmpty) return 0;

  if (text.contains(',')) {
    text = text.replaceAll('.', '').replaceAll(',', '.');
  }

  final value = double.tryParse(text);
  if (value == null || value < 0) return null;
  return value;
}

/// Total de um item: peça × quantidade + horas × valor da hora.
double valorTotalItem({
  required double valorPeca,
  required int quantidade,
  required double horasMaoObra,
  required double valorHora,
}) {
  return valorPeca * quantidade + horasMaoObra * valorHora;
}

/// Formata em reais no padrão brasileiro: "R$ 1.234,56".
String formatCurrencyBRL(double value) {
  final fixed = value.abs().toStringAsFixed(2);
  final parts = fixed.split('.');
  final inteiro = parts[0];
  final buffer = StringBuffer();

  for (var i = 0; i < inteiro.length; i++) {
    if (i > 0 && (inteiro.length - i) % 3 == 0) buffer.write('.');
    buffer.write(inteiro[i]);
  }

  final sinal = value < 0 ? '-' : '';
  return 'R\$ $sinal$buffer,${parts[1]}';
}

/// Formata um número para exibir num campo editável: "1234,5" → "1234,50".
String formatDecimalInput(double value, {int casas = 2}) {
  return value.toStringAsFixed(casas).replaceAll('.', ',');
}

/// Formata horas sem casas decimais desnecessárias: "2h", "1,5h".
String formatHoras(double horas) {
  final text = horas == horas.roundToDouble()
      ? horas.toStringAsFixed(0)
      : horas.toStringAsFixed(1).replaceAll('.', ',');
  return '${text}h';
}

/// Rótulo de exibição do tipo de intervenção gravado no Firestore.
String tipoIntervencaoLabel(String tipo) {
  switch (tipo) {
    case 'reparo':
      return 'Reparo';
    case 'substituicao':
      return 'Substituição';
    default:
      return tipo.isEmpty ? 'Substituição' : tipo;
  }
}

/// Soma de uma lista de itens gravados (mapas do Firestore), recalculada a
/// partir dos campos base — a mesma regra do laudo-service.
double somarItensOrcamento(Iterable<Map> itens) {
  var total = 0.0;

  for (final item in itens) {
    total += valorTotalItem(
      valorPeca: _num(item['valorPeca']),
      quantidade: _num(item['quantidade']) < 1 ? 1 : _num(item['quantidade']).round(),
      horasMaoObra: _num(item['horasMaoObra']),
      valorHora: item['valorHora'] == null
          ? kValorHoraLegado
          : _num(item['valorHora']),
    );
  }

  return total;
}

double _num(dynamic value) {
  if (value is num) return value.toDouble();
  return parseValorDecimal('${value ?? ''}') ?? 0;
}
