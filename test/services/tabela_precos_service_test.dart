// Testes do mapeamento modelo -> categoria da tabela de preços
// (lib/services/tabela_precos_service.dart). Deve casar com
// `_categoria_por_modelo` do agente ADK (precos_tool.py).
import 'package:argos_app/services/tabela_precos_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TabelaPrecosService.categoriaPorModelo', () {
    String cat(String modelo) => TabelaPrecosService.categoriaPorModelo(modelo);

    test('populares/compactos', () {
      expect(cat('Chevrolet Onix'), 'popular_compacto');
      expect(cat('Hyundai HB20 1.0'), 'popular_compacto');
      expect(cat('VW Up!'), 'popular_compacto');
      expect(cat('Renault Kwid'), 'popular_compacto');
    });

    test('médios e SUVs compactos', () {
      expect(cat('Toyota Corolla XEi'), 'medio_suv_compacto');
      expect(cat('Honda HR-V'), 'medio_suv_compacto');
      expect(cat('VW T-Cross'), 'medio_suv_compacto');
      expect(cat('Jeep Compass'), 'medio_suv_compacto');
    });

    test('SUVs grandes e picapes', () {
      expect(cat('Toyota Hilux SRV'), 'suv_grande_picape');
      expect(cat('Chevrolet S10'), 'suv_grande_picape');
      expect(cat('Mitsubishi Pajero Sport'), 'suv_grande_picape');
    });

    test('ignora caixa e espaços nas pontas', () {
      expect(cat('  COROLLA  '), 'medio_suv_compacto');
      expect(cat('hilux'), 'suv_grande_picape');
    });

    test('modelo desconhecido ou vazio cai no padrão popular_compacto', () {
      expect(cat(''), 'popular_compacto');
      expect(cat('Fusca 1975'), 'popular_compacto');
      expect(cat('Tesla Model 3'), 'popular_compacto');
    });
  });
}
