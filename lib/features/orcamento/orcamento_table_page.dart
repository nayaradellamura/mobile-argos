import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';

import '../../services/orcamento_arquivo_service.dart';
import '../../services/tabela_precos_service.dart';
import '../../services/valores_hora_service.dart';
import 'orcamento_calculo.dart';

int _idCounter = 0;

String _newItemId() =>
    'orc_${DateTime.now().microsecondsSinceEpoch}_${_idCounter++}';

/// Item da tabela de orçamento, no mesmo shape (camelCase) que o
/// `OrcamentoOficinaAgent` grava em `vistorias/{id}.orcamentoRascunho`
/// (ver `salvar_rascunho_orcamento` em `adk_agents/common/firestore_tools.py`)
/// e que esta tela devolve em `vistorias/{id}.orcamentoItensFinais` (fluxo
/// guiado) ou no rascunho do envio em massa.
class OrcamentoItemDraft {
  final String id;
  final String peca;
  final String tipoIntervencao;
  final int quantidade;
  final double valorPeca;
  final String tipoServico;
  final double horasMaoObra;
  final String origem;

  /// Mão de obra informada direto em reais (comum em orçamento de oficina),
  /// em vez de horas x valor da hora. Gravada como 1 h ao valor informado,
  /// para o total continuar sendo horas x valorHora no app, no agente e no
  /// laudo-service.
  final bool maoObraEmValor;
  final double valorMaoObra;

  OrcamentoItemDraft({
    String? id,
    required this.peca,
    this.tipoIntervencao = 'substituicao',
    this.quantidade = 1,
    this.valorPeca = 0,
    this.tipoServico = kTipoServicoPadrao,
    this.horasMaoObra = 0,
    this.origem = 'vistoria',
    this.maoObraEmValor = false,
    this.valorMaoObra = 0,
  }) : id = (id == null || id.isEmpty) ? _newItemId() : id;

  factory OrcamentoItemDraft.fromMap(Map<String, dynamic> map) {
    final tipoServico = map['tipoServico']?.toString() ?? '';
    final emValor = map['maoObraEmValor'] == true;

    return OrcamentoItemDraft(
      id: map['id']?.toString(),
      peca: map['peca']?.toString() ?? '',
      tipoIntervencao: map['tipoIntervencao']?.toString() ?? 'substituicao',
      quantidade: _toInt(map['quantidade']),
      valorPeca: _toDouble(map['valorPeca']),
      tipoServico: kTiposServico.containsKey(tipoServico)
          ? tipoServico
          : kTipoServicoPadrao,
      horasMaoObra: emValor ? 0 : _toDouble(map['horasMaoObra']),
      origem: map['origem']?.toString() ?? 'vistoria',
      maoObraEmValor: emValor,
      valorMaoObra: emValor ? _toDouble(map['valorMaoObra']) : 0,
    );
  }

  /// Mapa gravado no Firestore, com o valor da hora congelado no item.
  Map<String, dynamic> toMap({required double valorHora}) {
    final horas = maoObraEmValor
        ? (valorMaoObra > 0 ? 1.0 : 0.0)
        : horasMaoObra;
    final hora = maoObraEmValor ? valorMaoObra : valorHora;

    return {
      'id': id,
      'peca': peca.trim(),
      'tipoIntervencao': tipoIntervencao,
      'quantidade': quantidade,
      'valorPeca': valorPeca,
      'tipoServico': tipoServico,
      'horasMaoObra': horas,
      'valorHora': hora,
      'valorMaoObra': horas * hora,
      'valorTotal': valorTotalItem(
        valorPeca: valorPeca,
        quantidade: quantidade,
        horasMaoObra: horas,
        valorHora: hora,
      ),
      'origem': origem,
      if (maoObraEmValor) 'maoObraEmValor': true,
    };
  }

  static double _toDouble(dynamic value) {
    if (value is num) return value.toDouble();
    if (value is String) return parseValorDecimal(value) ?? 0;
    return 0;
  }

  static int _toInt(dynamic value) {
    final parsed = value is num ? value.toInt() : int.tryParse('$value');
    return (parsed == null || parsed < 1) ? 1 : parsed;
  }
}

/// Tela nativa de tabela editável de peças/orçamento — ver skill
/// `nova-captura-em-lote`: substitui a captura item-a-item no chat, que é
/// inviável em sinistros com 50+ peças. Usada nos dois fluxos (guiado e
/// envio em massa), então o cálculo e a validação são sempre os mesmos.
///
/// Devolve via `Navigator.pop` a lista completa e final de itens (já com o
/// valor da hora congelado em cada um), ou null se o mecânico fechar.
class OrcamentoTablePage extends StatefulWidget {
  final List<OrcamentoItemDraft> itensIniciais;

  /// Marca + modelo do veículo, para buscar o preço de referência certo.
  final String modeloVeiculo;

  final String submitLabel;

  /// Id do documento da vistoria. Com ele, a tela oferece importar um
  /// orçamento pronto (foto/print) lido pelo Gemini.
  final String? vistoriaDocId;

  const OrcamentoTablePage({
    super.key,
    this.itensIniciais = const [],
    this.modeloVeiculo = '',
    this.submitLabel = 'Enviar orçamento',
    this.vistoriaDocId,
  });

  @override
  State<OrcamentoTablePage> createState() => _OrcamentoTablePageState();
}

class _OrcamentoTablePageState extends State<OrcamentoTablePage> {
  final List<_EditableItem> _itens = [];
  Map<String, double> _valoresHora = {};
  bool _carregandoValoresHora = true;

  /// Lista compacta (uma linha por item; toque abre o card para editar).
  late bool _compacto = widget.itensIniciais.length > 4;
  String? _expandidoId;

  @override
  void initState() {
    super.initState();

    if (widget.itensIniciais.isEmpty) {
      _itens.add(_EditableItem.blank());
    } else {
      _itens.addAll(widget.itensIniciais.map(_EditableItem.fromDraft));
    }

    for (final item in _itens) {
      _attachLookup(item);
    }

    _carregarValoresHora();
  }

  @override
  void dispose() {
    for (final item in _itens) {
      item.dispose();
    }
    super.dispose();
  }

  Future<void> _carregarValoresHora() async {
    final valores = await ValoresHoraService.instance.carregar();

    if (!mounted) return;

    setState(() {
      _valoresHora = valores;
      _carregandoValoresHora = false;
    });

    // Oficina ainda não configurou nenhum valor: pede logo ao abrir, em vez
    // de deixar o mecânico preencher tudo e travar só no envio.
    if (valores.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _configurarValoresHora(primeiraVez: true);
      });
    }
  }

  /// Ao sair do campo da peça, busca preço/horas de referência — só se o
  /// mecânico ainda não digitou valor nem horas para esse item.
  void _attachLookup(_EditableItem item) {
    item.pecaFocus.addListener(() async {
      if (item.pecaFocus.hasFocus) return;
      if (item.valorController.text.trim().isNotEmpty ||
          item.horasController.text.trim().isNotEmpty) {
        return;
      }

      final referencia = await TabelaPrecosService.instance.buscar(
        peca: item.pecaController.text,
        modeloVeiculo: widget.modeloVeiculo,
      );

      if (referencia == null || !mounted || !_itens.contains(item)) return;
      if (item.valorController.text.trim().isNotEmpty ||
          item.horasController.text.trim().isNotEmpty) {
        return;
      }

      setState(() {
        if (referencia.valorPeca > 0) {
          item.valorController.text = formatDecimalInput(referencia.valorPeca);
        }
        if (referencia.horasMaoObra > 0) {
          item.horasController.text = formatDecimalInput(
            referencia.horasMaoObra,
            casas: 1,
          );
        }
        item.precoDeReferencia = true;
      });
    });
  }

  Future<void> _configurarValoresHora({bool primeiraVez = false}) async {
    final tiposUsados = _itens
        .where(
          (item) =>
              !item.isBlank &&
              !item.maoObraEmValor &&
              (item.horasMaoObra ?? 0) > 0,
        )
        .map((item) => item.tipoServico)
        .toSet();

    final novos = await showDialog<Map<String, double>>(
      context: context,
      builder: (_) => _ValoresHoraDialog(
        valoresAtuais: _valoresHora,
        tiposDestacados: tiposUsados,
        primeiraVez: primeiraVez,
      ),
    );

    if (novos == null || !mounted) return;

    setState(() => _valoresHora = novos);

    try {
      await ValoresHoraService.instance.salvar(novos);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Os valores serão usados neste orçamento, mas não foi possível '
            'salvá-los na oficina.',
          ),
        ),
      );
    }
  }

  bool get _podeImportar => (widget.vistoriaDocId ?? '').trim().isNotEmpty;

  /// Atalho opcional: lê um orçamento pronto (foto ou print) com o Gemini e
  /// preenche a tabela. O mecânico confere e corrige antes de salvar.
  Future<void> _importarOrcamento() async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 16, 8, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  'Importar orçamento pronto',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.photo_camera_outlined),
                title: const Text('Tirar foto do orçamento'),
                onTap: () => Navigator.of(sheetContext).pop(ImageSource.camera),
              ),
              ListTile(
                leading: const Icon(Icons.photo_library_outlined),
                title: const Text('Escolher imagem ou print'),
                subtitle: const Text(
                  'Foto do papel, print do PDF ou da planilha',
                ),
                onTap: () =>
                    Navigator.of(sheetContext).pop(ImageSource.gallery),
              ),
            ],
          ),
        ),
      ),
    );

    if (source == null || !mounted) return;

    final XFile? arquivo;
    try {
      arquivo = await ImagePicker().pickImage(
        source: source,
        imageQuality: 85,
        maxWidth: 2400,
      );
    } catch (e) {
      debugPrint('Erro ao escolher imagem do orçamento: $e');
      _mostrarAviso('Não foi possível abrir a câmera ou a galeria.');
      return;
    }

    if (arquivo == null || !mounted) return;

    final bytes = await arquivo.readAsBytes();
    if (!mounted) return;

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const PopScope(
        canPop: false,
        child: AlertDialog(
          content: Row(
            children: [
              SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2.5),
              ),
              SizedBox(width: 16),
              Expanded(child: Text('Lendo o orçamento...')),
            ],
          ),
        ),
      ),
    );

    OrcamentoArquivoResultado? resultado;
    String? erro;
    try {
      resultado = await OrcamentoArquivoService.instance.importar(
        vistoriaDocId: widget.vistoriaDocId!.trim(),
        bytes: bytes,
        nomeArquivo: arquivo.name.isEmpty ? 'orcamento.jpg' : arquivo.name,
        mimeType: arquivo.mimeType ?? 'image/jpeg',
      );
    } on FirebaseFunctionsException catch (e) {
      debugPrint('Erro ao importar orçamento: ${e.code} ${e.message}');
      erro = e.code == 'invalid-argument' && (e.message ?? '').isNotEmpty
          ? e.message
          : 'Não foi possível ler o orçamento agora. Tente de novo.';
    } catch (e) {
      debugPrint('Erro ao importar orçamento: $e');
      erro = 'Não foi possível enviar o arquivo. Verifique a conexão.';
    }

    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pop();

    if (erro != null) {
      _mostrarAviso(erro);
      return;
    }

    if (resultado == null || !resultado.legivel || resultado.itens.isEmpty) {
      _mostrarAviso(
        'Não deu para ler os itens. Tente uma foto mais nítida, com o '
        'orçamento inteiro e bem iluminado.',
      );
      return;
    }

    await _aplicarImportacao(resultado);
  }

  Future<void> _aplicarImportacao(OrcamentoArquivoResultado resultado) async {
    final drafts = resultado.itens.map((item) {
      final tipo = kTiposServico.containsKey(item.tipoServico)
          ? item.tipoServico
          : kTipoServicoPadrao;
      final horas = item.horasMaoObra ?? 0;
      final valorHoraDoc = item.valorHora;
      final valorHoraOficina = _valoresHora[tipo];

      // Fica em horas só quando o documento traz horas e o valor da hora
      // dele é o da oficina (ou não traz valor nenhum). Fora isso, vale o
      // valor em reais do documento, para o total bater com o orçamento.
      final usaHoras =
          horas > 0 &&
          item.valorMaoObra == null &&
          (valorHoraDoc == null ||
              (valorHoraOficina != null &&
                  (valorHoraDoc - valorHoraOficina).abs() < 0.01));

      final valorMaoObra =
          item.valorMaoObra ??
          (horas > 0 && valorHoraDoc != null ? horas * valorHoraDoc : 0);

      return OrcamentoItemDraft(
        peca: item.peca,
        tipoIntervencao: item.tipoIntervencao,
        quantidade: item.quantidade,
        valorPeca: item.valorPeca,
        tipoServico: tipo,
        horasMaoObra: usaHoras ? horas : 0,
        maoObraEmValor: !usaHoras && valorMaoObra > 0,
        valorMaoObra: usaHoras ? 0 : valorMaoObra,
        origem: 'arquivo',
      );
    }).toList();

    var substituir = true;
    if (_itensPreenchidos.isNotEmpty) {
      final escolha = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text('${drafts.length} itens lidos'),
          content: const Text(
            'Quer substituir os itens da tabela pelos do orçamento ou '
            'adicionar ao final?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancelar'),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Adicionar'),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Substituir'),
            ),
          ],
        ),
      );
      if (escolha == null || !mounted) return;
      substituir = escolha;
    }

    setState(() {
      if (substituir) {
        for (final item in _itens) {
          item.dispose();
        }
        _itens.clear();
      } else {
        _itens.removeWhere((item) {
          if (!item.isBlank) return false;
          item.dispose();
          return true;
        });
      }

      for (final draft in drafts) {
        final item = _EditableItem.fromDraft(draft);
        _attachLookup(item);
        _itens.add(item);
      }
    });

    final avisos = <String>[
      '${drafts.length} itens importados. Confira os valores antes de salvar.',
      if (resultado.totalDocumento != null)
        'Total no documento: ${formatCurrencyBRL(resultado.totalDocumento!)}.',
      if ((resultado.observacao ?? '').isNotEmpty) resultado.observacao!,
    ];
    _mostrarAviso(avisos.join(' '), duracao: const Duration(seconds: 6));
  }

  void _mostrarAviso(String texto, {Duration? duracao}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(texto),
        duration: duracao ?? const Duration(seconds: 4),
      ),
    );
  }

  void _addBlankItem() {
    final item = _EditableItem.blank();
    _attachLookup(item);
    setState(() {
      _itens.add(item);
      _expandidoId = item.id;
    });
  }

  void _removeItem(int index) {
    final removed = _itens.removeAt(index);
    setState(() {});

    final nome = removed.pecaController.text.trim();
    final messenger = ScaffoldMessenger.of(context)..hideCurrentSnackBar();
    var desfeito = false;

    messenger
        .showSnackBar(
          SnackBar(
            content: Text(
              nome.isEmpty ? 'Item excluído.' : '"$nome" excluído.',
            ),
            action: SnackBarAction(
              label: 'Desfazer',
              onPressed: () {
                if (!mounted) return;
                desfeito = true;
                setState(() {
                  _itens.insert(index.clamp(0, _itens.length), removed);
                });
              },
            ),
          ),
        )
        .closed
        .then((_) {
          if (!desfeito) removed.dispose();
        });
  }

  /// Fecha a tela; se já houver itens, confirma antes de descartar.
  Future<void> _closePage() async {
    if (await _confirmarDescarte() && mounted) {
      Navigator.of(context).pop<List<Map<String, dynamic>>?>(null);
    }
  }

  Future<bool> _confirmarDescarte() async {
    final quantidade = _itensPreenchidos.length;
    if (quantidade == 0) return true;

    final descartar = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Sair sem salvar?'),
        content: Text(
          quantidade == 1
              ? 'O item da tabela não será salvo.'
              : 'Os $quantidade itens da tabela não serão salvos.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Continuar editando'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
            child: const Text('Sair sem salvar'),
          ),
        ],
      ),
    );

    return descartar ?? false;
  }

  /// Na lista compacta, abre o primeiro item com erro.
  void _abrirPrimeiroErro() {
    for (final item in _itens) {
      if (_erroDoItem(item) != null) {
        setState(() => _expandidoId = item.id);
        return;
      }
    }
  }

  List<_EditableItem> get _itensPreenchidos =>
      _itens.where((item) => !item.isBlank).toList();

  String? _erroDoItem(_EditableItem item) {
    if (item.isBlank) return null;
    return item.erroValidacao ??
        (_semValorHora(item)
            ? 'Configure o valor da hora de '
                  '${tipoServicoLabel(item.tipoServico).toLowerCase()}.'
            : null);
  }

  bool _semValorHora(_EditableItem item) =>
      !item.maoObraEmValor &&
      (item.horasMaoObra ?? 0) > 0 &&
      !_valoresHora.containsKey(item.tipoServico);

  double _valorHora(String tipoServico) => _valoresHora[tipoServico] ?? 0;

  double _maoObraDoItem(_EditableItem item) => item.maoObraEmValor
      ? (item.valorMaoObra ?? 0)
      : (item.horasMaoObra ?? 0) * _valorHora(item.tipoServico);

  double? _totalDoItem(_EditableItem item) {
    if (item.isBlank || _erroDoItem(item) != null) return null;
    return (item.valorPeca ?? 0) * (item.quantidade ?? 1) +
        _maoObraDoItem(item);
  }

  void _submit() {
    final itens = _itensPreenchidos;
    if (itens.isEmpty || itens.any((item) => _erroDoItem(item) != null)) {
      return;
    }

    final result = itens.map((item) {
      final draft = item.toDraft();
      return draft.toMap(valorHora: _valorHora(draft.tipoServico));
    }).toList();

    Navigator.of(context).pop<List<Map<String, dynamic>>>(result);
  }

  @override
  Widget build(BuildContext context) {
    final preenchidos = _itensPreenchidos;
    final comErro = preenchidos.where((i) => _erroDoItem(i) != null).length;
    final faltaValorHora = preenchidos.any(_semValorHora);
    final canSubmit =
        preenchidos.isNotEmpty && comErro == 0 && !_carregandoValoresHora;

    var totalPecas = 0.0;
    var totalMaoObra = 0.0;
    var totalHoras = 0.0;

    for (final item in preenchidos) {
      totalPecas += (item.valorPeca ?? 0) * (item.quantidade ?? 1);
      if (!item.maoObraEmValor) totalHoras += item.horasMaoObra ?? 0;
      totalMaoObra += _maoObraDoItem(item);
    }

    final String submitText;
    if (canSubmit) {
      submitText =
          '${widget.submitLabel} (${preenchidos.length} '
          'ite${preenchidos.length > 1 ? 'ns' : 'm'})';
    } else if (preenchidos.isEmpty) {
      submitText = 'Adicione pelo menos 1 peça';
    } else if (_carregandoValoresHora) {
      submitText = 'Carregando valores da oficina...';
    } else {
      submitText = comErro == 1 ? 'Corrija 1 item' : 'Corrija $comErro itens';
    }

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _closePage();
      },
      child: Scaffold(
        backgroundColor: const Color(0xFFF3FBFF),
        body: SafeArea(
          child: Column(
            children: [
              _OrcamentoHeader(
                itemCount: preenchidos.length,
                compacto: _compacto,
                onClose: _closePage,
                onConfigurarValorHora: _configurarValoresHora,
                onAlternarVisualizacao: () => setState(() {
                  _compacto = !_compacto;
                  _expandidoId = null;
                }),
              ),
              if (faltaValorHora)
                _ValorHoraBanner(onTap: _configurarValoresHora),
              Expanded(
                child: ListView.separated(
                  padding: const EdgeInsets.fromLTRB(18, 18, 18, 100),
                  itemCount: _itens.length + 1 + (_podeImportar ? 1 : 0),
                  separatorBuilder: (_, __) => const SizedBox(height: 12),
                  itemBuilder: (context, rawIndex) {
                    if (_podeImportar && rawIndex == 0) {
                      return _ImportarOrcamentoButton(
                        onTap: _importarOrcamento,
                      );
                    }

                    final index = rawIndex - (_podeImportar ? 1 : 0);

                    if (index == _itens.length) {
                      return _AddItemButton(onTap: _addBlankItem);
                    }

                    final item = _itens[index];

                    if (_compacto && item.id != _expandidoId) {
                      return _OrcamentoItemLinha(
                        item: item,
                        maoObra: _maoObraDoItem(item),
                        total: _totalDoItem(item),
                        erro: _erroDoItem(item),
                        onTap: () => setState(() => _expandidoId = item.id),
                      );
                    }

                    return _OrcamentoItemCard(
                      item: item,
                      valorHora: _valoresHora[item.tipoServico],
                      total: _totalDoItem(item),
                      erro: _erroDoItem(item),
                      onChanged: () => setState(() {}),
                      onRecolher: _compacto
                          ? () => setState(() => _expandidoId = null)
                          : null,
                      onRemove: _itens.length > 1
                          ? () => _removeItem(index)
                          : null,
                    );
                  },
                ),
              ),
            ],
          ),
        ),
        bottomNavigationBar: SafeArea(
          child: Container(
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 16),
            decoration: BoxDecoration(
              color: Colors.white,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(.06),
                  blurRadius: 18,
                  offset: const Offset(0, -6),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _TotalRow(label: 'Peças', value: formatCurrencyBRL(totalPecas)),
                const SizedBox(height: 2),
                _TotalRow(
                  label: totalHoras > 0
                      ? 'Mão de obra (${formatHoras(totalHoras)})'
                      : 'Mão de obra',
                  value: formatCurrencyBRL(totalMaoObra),
                ),
                const SizedBox(height: 4),
                _TotalRow(
                  label: 'Total',
                  value: formatCurrencyBRL(totalPecas + totalMaoObra),
                  destaque: true,
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  height: 54,
                  child: ElevatedButton.icon(
                    onPressed: canSubmit
                        ? _submit
                        : (comErro > 0 && _compacto
                              ? _abrirPrimeiroErro
                              : null),
                    icon: Icon(
                      canSubmit ? Icons.check_circle : Icons.lock_outline,
                    ),
                    label: Text(submitText),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF0057C0),
                      foregroundColor: Colors.white,
                      disabledBackgroundColor: const Color(0xFFE5F6FF),
                      disabledForegroundColor: const Color(0xFF94A3B8),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(18),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _EditableItem {
  final String id;
  final TextEditingController pecaController;
  final TextEditingController quantidadeController;
  final TextEditingController valorController;
  final TextEditingController horasController;
  final TextEditingController valorMaoObraController;
  final FocusNode pecaFocus = FocusNode();
  String tipoIntervencao;
  String tipoServico;
  bool maoObraEmValor;
  final String origem;
  bool precoDeReferencia = false;

  _EditableItem({
    required this.id,
    required this.pecaController,
    required this.quantidadeController,
    required this.valorController,
    required this.horasController,
    required this.valorMaoObraController,
    required this.tipoIntervencao,
    required this.tipoServico,
    required this.origem,
    this.maoObraEmValor = false,
  });

  factory _EditableItem.blank() {
    return _EditableItem(
      id: _newItemId(),
      pecaController: TextEditingController(),
      quantidadeController: TextEditingController(text: '1'),
      valorController: TextEditingController(),
      horasController: TextEditingController(),
      valorMaoObraController: TextEditingController(),
      tipoIntervencao: 'substituicao',
      tipoServico: kTipoServicoPadrao,
      origem: 'vistoria',
    );
  }

  factory _EditableItem.fromDraft(OrcamentoItemDraft draft) {
    return _EditableItem(
      id: draft.id,
      pecaController: TextEditingController(text: draft.peca),
      quantidadeController: TextEditingController(text: '${draft.quantidade}'),
      valorController: TextEditingController(
        text: draft.valorPeca > 0 ? formatDecimalInput(draft.valorPeca) : '',
      ),
      horasController: TextEditingController(
        text: draft.horasMaoObra > 0
            ? formatDecimalInput(draft.horasMaoObra, casas: 1)
            : '',
      ),
      valorMaoObraController: TextEditingController(
        text: draft.valorMaoObra > 0
            ? formatDecimalInput(draft.valorMaoObra)
            : '',
      ),
      tipoIntervencao: draft.tipoIntervencao,
      tipoServico: draft.tipoServico,
      origem: draft.origem,
      maoObraEmValor: draft.maoObraEmValor,
    );
  }

  /// Linha nova, ainda não tocada — é ignorada no envio e na validação.
  bool get isBlank =>
      pecaController.text.trim().isEmpty &&
      valorController.text.trim().isEmpty &&
      horasController.text.trim().isEmpty &&
      valorMaoObraController.text.trim().isEmpty;

  double? get valorPeca => parseValorDecimal(valorController.text);

  double? get horasMaoObra => parseValorDecimal(horasController.text);

  double? get valorMaoObra => parseValorDecimal(valorMaoObraController.text);

  int? get quantidade {
    final value = int.tryParse(quantidadeController.text.trim());
    return (value == null || value < 1) ? null : value;
  }

  String? get erroValidacao {
    if (pecaController.text.trim().isEmpty) return 'Informe o nome da peça.';
    if (quantidade == null) return 'Quantidade inválida.';
    if (valorPeca == null) return 'Valor da peça inválido.';
    if (maoObraEmValor) {
      if (valorMaoObra == null) return 'Valor da mão de obra inválido.';
      if (valorPeca == 0 && valorMaoObra == 0) {
        return 'Informe o valor da peça ou o da mão de obra.';
      }
      return null;
    }
    if (horasMaoObra == null) return 'Horas de mão de obra inválidas.';
    if (valorPeca == 0 && horasMaoObra == 0) {
      return 'Informe o valor da peça ou as horas de mão de obra.';
    }
    return null;
  }

  OrcamentoItemDraft toDraft() {
    return OrcamentoItemDraft(
      id: id,
      peca: pecaController.text.trim(),
      tipoIntervencao: tipoIntervencao,
      quantidade: quantidade ?? 1,
      valorPeca: valorPeca ?? 0,
      tipoServico: tipoServico,
      horasMaoObra: maoObraEmValor ? 0 : (horasMaoObra ?? 0),
      origem: origem,
      maoObraEmValor: maoObraEmValor,
      valorMaoObra: maoObraEmValor ? (valorMaoObra ?? 0) : 0,
    );
  }

  void dispose() {
    pecaController.dispose();
    quantidadeController.dispose();
    valorController.dispose();
    horasController.dispose();
    valorMaoObraController.dispose();
    pecaFocus.dispose();
  }
}

class _TotalRow extends StatelessWidget {
  final String label;
  final String value;
  final bool destaque;

  const _TotalRow({
    required this.label,
    required this.value,
    this.destaque = false,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: TextStyle(
            color: destaque ? const Color(0xFF1F2937) : const Color(0xFF414755),
            fontWeight: destaque ? FontWeight.w800 : FontWeight.w600,
            fontSize: destaque ? 14 : 12,
          ),
        ),
        Text(
          value,
          style: TextStyle(
            color: destaque ? const Color(0xFF0057C0) : const Color(0xFF1F2937),
            fontWeight: FontWeight.w800,
            fontSize: destaque ? 16 : 13,
          ),
        ),
      ],
    );
  }
}

class _OrcamentoHeader extends StatelessWidget {
  final int itemCount;
  final bool compacto;
  final VoidCallback onClose;
  final VoidCallback onConfigurarValorHora;
  final VoidCallback onAlternarVisualizacao;

  const _OrcamentoHeader({
    required this.itemCount,
    required this.compacto,
    required this.onClose,
    required this.onConfigurarValorHora,
    required this.onAlternarVisualizacao,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(.92),
        border: Border(
          bottom: BorderSide(color: Colors.black.withOpacity(.05)),
        ),
      ),
      child: Row(
        children: [
          Material(
            color: const Color(0xFFE5F6FF),
            borderRadius: BorderRadius.circular(16),
            child: InkWell(
              onTap: onClose,
              borderRadius: BorderRadius.circular(16),
              child: const Tooltip(
                message: 'Fechar',
                child: SizedBox(
                  width: 44,
                  height: 44,
                  child: Icon(Icons.close, color: Color(0xFF0057C0)),
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Orçamento ($itemCount)',
                  style: GoogleFonts.spaceGrotesk(
                    color: const Color(0xFF1F2937),
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 2),
                const Text(
                  'Revise os valores e ajuste o que precisar.',
                  style: TextStyle(
                    color: Color(0xFF6B7280),
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: onAlternarVisualizacao,
            tooltip: compacto ? 'Ver em cards' : 'Ver lista compacta',
            icon: Icon(
              compacto ? Icons.view_agenda_outlined : Icons.view_list_rounded,
              color: const Color(0xFF0057C0),
            ),
          ),
          TextButton.icon(
            onPressed: onConfigurarValorHora,
            icon: const Icon(Icons.schedule_rounded, size: 18),
            label: const Text('Valor da hora'),
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xFF0057C0),
              textStyle: const TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ValorHoraBanner extends StatelessWidget {
  final VoidCallback onTap;

  const _ValorHoraBanner({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFFFFF4E5),
      child: InkWell(
        onTap: onTap,
        child: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          child: Row(
            children: [
              Icon(Icons.info_outline, color: Color(0xFFB45309), size: 20),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Falta configurar o valor da hora de algum tipo de serviço.',
                  style: TextStyle(
                    color: Color(0xFF92400E),
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  ),
                ),
              ),
              Text(
                'Configurar',
                style: TextStyle(
                  color: Color(0xFFB45309),
                  fontWeight: FontWeight.w900,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Pop-up de configuração do valor da hora da oficina, por tipo de serviço.
class _ValoresHoraDialog extends StatefulWidget {
  final Map<String, double> valoresAtuais;
  final Set<String> tiposDestacados;
  final bool primeiraVez;

  const _ValoresHoraDialog({
    required this.valoresAtuais,
    required this.tiposDestacados,
    required this.primeiraVez,
  });

  @override
  State<_ValoresHoraDialog> createState() => _ValoresHoraDialogState();
}

class _ValoresHoraDialogState extends State<_ValoresHoraDialog> {
  late final Map<String, TextEditingController> _controllers = {
    for (final tipo in kTiposServico.keys)
      tipo: TextEditingController(
        text: widget.valoresAtuais[tipo] != null
            ? formatDecimalInput(widget.valoresAtuais[tipo]!)
            : '',
      ),
  };

  String? _erro;

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  void _salvar() {
    final valores = <String, double>{};

    for (final entry in _controllers.entries) {
      final value = parseValorDecimal(entry.value.text);

      if (value == null) {
        setState(
          () => _erro =
              'Valor inválido em ${tipoServicoLabel(entry.key).toLowerCase()}.',
        );
        return;
      }

      if (value > 0) valores[entry.key] = value;
    }

    if (valores.isEmpty) {
      setState(
        () => _erro = 'Informe o valor de pelo menos um tipo de serviço.',
      );
      return;
    }

    Navigator.of(context).pop(valores);
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 24),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Valor da hora da oficina',
              style: GoogleFonts.spaceGrotesk(
                fontSize: 17,
                fontWeight: FontWeight.bold,
                color: const Color(0xFF1F2937),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              widget.primeiraVez
                  ? 'Antes de montar o orçamento, informe quanto a oficina '
                        'cobra por hora em cada tipo de serviço. Os valores '
                        'ficam salvos para os próximos orçamentos.'
                  : 'Os valores ficam salvos para os próximos orçamentos. '
                        'Orçamentos já enviados não mudam.',
              style: const TextStyle(color: Color(0xFF6B7280), fontSize: 12),
            ),
            const SizedBox(height: 12),
            for (final entry in kTiposServico.entries) ...[
              TextField(
                controller: _controllers[entry.key],
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
                ],
                decoration: InputDecoration(
                  labelText: '${entry.value} (R\$/hora)',
                  helperText:
                      widget.tiposDestacados.contains(entry.key) &&
                          !widget.valoresAtuais.containsKey(entry.key)
                      ? 'Usado neste orçamento'
                      : null,
                ),
              ),
              const SizedBox(height: 6),
            ],
            if (_erro != null) ...[
              const SizedBox(height: 6),
              Text(
                _erro!,
                style: const TextStyle(color: Colors.redAccent, fontSize: 12),
              ),
            ],
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(widget.primeiraVez ? 'Depois' : 'Cancelar'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF0057C0),
                      foregroundColor: Colors.white,
                    ),
                    onPressed: _salvar,
                    child: const Text('Salvar'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _OrcamentoItemCard extends StatelessWidget {
  final _EditableItem item;
  final double? valorHora;
  final double? total;
  final String? erro;
  final VoidCallback onChanged;
  final VoidCallback? onRecolher;
  final VoidCallback? onRemove;

  const _OrcamentoItemCard({
    required this.item,
    required this.valorHora,
    required this.total,
    required this.erro,
    required this.onChanged,
    this.onRecolher,
    this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final isSugestao = item.origem == 'sugestao_aceita';
    final isArquivo = item.origem == 'arquivo';
    final totalItem = total;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: erro != null ? Colors.redAccent : const Color(0xFFE5F6FF),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: item.pecaController,
                  focusNode: item.pecaFocus,
                  onChanged: (_) => onChanged(),
                  textCapitalization: TextCapitalization.sentences,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                  ),
                  decoration: const InputDecoration(
                    hintText: 'Nome da peça',
                    isDense: true,
                    border: InputBorder.none,
                  ),
                ),
              ),
              if (onRemove != null)
                IconButton(
                  onPressed: onRemove,
                  tooltip: 'Excluir item',
                  icon: const Icon(
                    Icons.delete_outline,
                    color: Colors.redAccent,
                    size: 20,
                  ),
                  visualDensity: VisualDensity.compact,
                ),
              if (onRecolher != null)
                IconButton(
                  onPressed: onRecolher,
                  tooltip: 'Recolher',
                  icon: const Icon(
                    Icons.expand_less_rounded,
                    color: Color(0xFF0057C0),
                    size: 22,
                  ),
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
          if (isSugestao || isArquivo || item.precoDeReferencia) ...[
            const SizedBox(height: 4),
            Wrap(
              spacing: 6,
              children: [
                if (isSugestao) const _Tag('Sugerida pela IA'),
                if (isArquivo) const _Tag('Lida do orçamento'),
                if (item.precoDeReferencia) const _Tag('Preço de referência'),
              ],
            ),
          ],
          const SizedBox(height: 10),
          Row(
            children: [
              for (final tipo in const ['substituicao', 'reparo']) ...[
                Expanded(
                  child: _ChoiceChip(
                    label: tipoIntervencaoLabel(tipo),
                    selected: item.tipoIntervencao == tipo,
                    onTap: () {
                      item.tipoIntervencao = tipo;
                      onChanged();
                    },
                  ),
                ),
                if (tipo == 'substituicao') const SizedBox(width: 8),
              ],
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              SizedBox(
                width: 56,
                child: _NumberField(
                  label: 'Qtd.',
                  controller: item.quantidadeController,
                  onChanged: onChanged,
                  allowDecimal: false,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _NumberField(
                  label: 'Valor unitário (R\$)',
                  controller: item.valorController,
                  onChanged: onChanged,
                  allowDecimal: true,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const Text(
            'Mão de obra',
            style: TextStyle(
              color: Color(0xFF9CA3AF),
              fontSize: 10,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final entry in kTiposServico.entries)
                _ChoiceChip(
                  label: entry.value,
                  selected: item.tipoServico == entry.key,
                  compact: true,
                  onTap: () {
                    item.tipoServico = entry.key;
                    onChanged();
                  },
                ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              _ChoiceChip(
                label: 'Em horas',
                selected: !item.maoObraEmValor,
                compact: true,
                onTap: () {
                  item.maoObraEmValor = false;
                  onChanged();
                },
              ),
              const SizedBox(width: 6),
              _ChoiceChip(
                label: 'Em reais',
                selected: item.maoObraEmValor,
                compact: true,
                onTap: () {
                  item.maoObraEmValor = true;
                  onChanged();
                },
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (item.maoObraEmValor)
            _NumberField(
              label: 'Valor da mão de obra (R\$)',
              controller: item.valorMaoObraController,
              onChanged: onChanged,
              allowDecimal: true,
            )
          else
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: _NumberField(
                    label: 'Horas',
                    controller: item.horasController,
                    onChanged: onChanged,
                    allowDecimal: true,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    valorHora != null
                        ? '× ${formatCurrencyBRL(valorHora!)}/h'
                        : 'Valor da hora não configurado',
                    style: TextStyle(
                      color: valorHora != null
                          ? const Color(0xFF6B7280)
                          : const Color(0xFFB45309),
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          if (erro != null) ...[
            const SizedBox(height: 10),
            Text(
              erro!,
              style: const TextStyle(
                color: Colors.redAccent,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ] else if (totalItem != null) ...[
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerRight,
              child: Text(
                'Total do item: ${formatCurrencyBRL(totalItem)}',
                style: const TextStyle(
                  color: Color(0xFF1F2937),
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  final String label;

  const _Tag(this.label);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF4E5),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: Color(0xFFB45309),
          fontSize: 10,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

class _ChoiceChip extends StatelessWidget {
  final String label;
  final bool selected;
  final bool compact;
  final VoidCallback onTap;

  const _ChoiceChip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? const Color(0xFF0057C0) : const Color(0xFFF3FBFF),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          alignment: compact ? null : Alignment.center,
          padding: EdgeInsets.symmetric(
            vertical: compact ? 7 : 9,
            horizontal: compact ? 12 : 0,
          ),
          child: Text(
            label,
            style: TextStyle(
              color: selected ? Colors.white : const Color(0xFF414755),
              fontWeight: FontWeight.w700,
              fontSize: 12,
            ),
          ),
        ),
      ),
    );
  }
}

class _NumberField extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final VoidCallback onChanged;
  final bool allowDecimal;

  const _NumberField({
    required this.label,
    required this.controller,
    required this.onChanged,
    this.allowDecimal = false,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            color: Color(0xFF9CA3AF),
            fontSize: 10,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 2),
        TextField(
          controller: controller,
          onChanged: (_) => onChanged(),
          keyboardType: TextInputType.numberWithOptions(decimal: allowDecimal),
          inputFormatters: [
            FilteringTextInputFormatter.allow(
              allowDecimal ? RegExp(r'[0-9.,]') : RegExp(r'[0-9]'),
            ),
          ],
          style: const TextStyle(
            fontWeight: FontWeight.w800,
            fontSize: 14,
            color: Color(0xFF1F2937),
          ),
          decoration: const InputDecoration(
            hintText: '0',
            isDense: true,
            contentPadding: EdgeInsets.symmetric(vertical: 6),
            border: UnderlineInputBorder(
              borderSide: BorderSide(color: Color(0xFFE5F6FF)),
            ),
            focusedBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: Color(0xFF0057C0)),
            ),
          ),
        ),
      ],
    );
  }
}

class _AddItemButton extends StatelessWidget {
  final VoidCallback onTap;

  const _AddItemButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: const Color(0xFF0057C0).withOpacity(.35)),
          ),
          alignment: Alignment.center,
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.add, color: Color(0xFF0057C0), size: 18),
              SizedBox(width: 6),
              Text(
                'Adicionar peça',
                style: TextStyle(
                  color: Color(0xFF0057C0),
                  fontWeight: FontWeight.w800,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Atalho opcional para preencher a tabela a partir de um orçamento pronto.
class _ImportarOrcamentoButton extends StatelessWidget {
  final VoidCallback onTap;

  const _ImportarOrcamentoButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFFE5F6FF),
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Icon(Icons.document_scanner_outlined, color: Color(0xFF0057C0)),
              SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Importar orçamento pronto',
                      style: TextStyle(
                        color: Color(0xFF0057C0),
                        fontWeight: FontWeight.w800,
                        fontSize: 14,
                      ),
                    ),
                    SizedBox(height: 2),
                    Text(
                      'Opcional: foto ou print do orçamento da oficina. '
                      'A IA preenche a tabela para você conferir.',
                      style: TextStyle(color: Color(0xFF475569), fontSize: 12),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: Color(0xFF0057C0)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Item na lista compacta: uma linha com peça, valores e total. O toque abre
/// o card completo desse item para editar.
class _OrcamentoItemLinha extends StatelessWidget {
  final _EditableItem item;
  final double maoObra;
  final double? total;
  final String? erro;
  final VoidCallback onTap;

  const _OrcamentoItemLinha({
    required this.item,
    required this.maoObra,
    required this.total,
    required this.erro,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final nome = item.pecaController.text.trim();
    final quantidade = item.quantidade ?? 1;
    final valorPeca = item.valorPeca ?? 0;

    final detalhes = <String>[
      if (valorPeca > 0)
        quantidade > 1
            ? '$quantidade × ${formatCurrencyBRL(valorPeca)}'
            : formatCurrencyBRL(valorPeca),
      if (maoObra > 0) 'MO ${formatCurrencyBRL(maoObra)}',
    ];

    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: erro != null ? Colors.redAccent : const Color(0xFFE5F6FF),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      nome.isEmpty ? 'Nova peça' : nome,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                        color: nome.isEmpty
                            ? const Color(0xFF9CA3AF)
                            : const Color(0xFF1F2937),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      erro ??
                          (detalhes.isEmpty
                              ? 'Sem valores'
                              : detalhes.join(' · ')),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: erro != null
                            ? Colors.redAccent
                            : const Color(0xFF6B7280),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              if (total != null)
                Text(
                  formatCurrencyBRL(total!),
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 13,
                    color: Color(0xFF1F2937),
                  ),
                )
              else if (erro != null)
                const Icon(
                  Icons.error_outline,
                  color: Colors.redAccent,
                  size: 20,
                ),
              const SizedBox(width: 4),
              const Icon(
                Icons.chevron_right,
                color: Color(0xFF9CA3AF),
                size: 20,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
