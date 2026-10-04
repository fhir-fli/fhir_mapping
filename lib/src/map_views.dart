import 'package:fhir_node/fhir_node.dart';

/// Views over a StructureMap and a ConceptMap read by element name, so the
/// engine and the parser's renderer serve every version's shape: R4B's
/// `dependent.variable` and R5's `dependent.parameter`, R4B's
/// `equivalence` and R5's `relationship`, the presence or absence of
/// `target.contextType`.
String? _text(FhirNode node, String name) =>
    node.getChildByName(name)?.primitiveValue;

List<String> _texts(FhirNode node, String name) => [
  for (final c in node.getChildrenByName(name))
    if (c.primitiveValue case final String v) v,
];

/// A StructureMap.
class MapView {
  /// Wraps a StructureMap [node].
  const MapView(this.node);

  /// The StructureMap itself.
  final FhirNode node;

  /// `StructureMap.url`.
  String? get url => _text(node, 'url');

  /// `StructureMap.name`.
  String? get name => _text(node, 'name');

  /// `StructureMap.title`.
  String? get title => _text(node, 'title');

  /// `StructureMap.status`.
  String? get status => _text(node, 'status');

  /// `StructureMap.description`.
  String? get description => _text(node, 'description');

  /// `StructureMap.contained`.
  List<FhirNode> get contained => node.getChildrenByName('contained');

  /// `StructureMap.structure`, the `uses` statements.
  List<StructureView> get structures => [
    for (final s in node.getChildrenByName('structure')) StructureView(s),
  ];

  /// `StructureMap.import`, the `imports` statements.
  List<String> get imports => _texts(node, 'import');

  /// `StructureMap.group`.
  List<GroupView> get groups => [
    for (final g in node.getChildrenByName('group')) GroupView(g),
  ];
}

/// A `uses` statement: `StructureMap.structure`.
class StructureView {
  /// Wraps a structure [node].
  const StructureView(this.node);

  /// The structure node itself.
  final FhirNode node;

  /// `structure.url`.
  String? get url => _text(node, 'url');

  /// `structure.alias`.
  String? get alias => _text(node, 'alias');

  /// `structure.mode` (`source`, `target`, `queried`, `produced`).
  String? get mode => _text(node, 'mode');

  /// `structure.documentation`.
  String? get documentation => _text(node, 'documentation');
}

/// A `StructureMap.group`.
class GroupView {
  /// Wraps a group [node].
  const GroupView(this.node);

  /// The group node itself.
  final FhirNode node;

  /// `group.name`.
  String? get name => _text(node, 'name');

  /// `group.extends`.
  String? get extends_ => _text(node, 'extends');

  /// `group.typeMode` (`none`, `types`, `type-and-types`), null when not
  /// given (R5 made it optional).
  String? get typeMode => _text(node, 'typeMode');

  /// `group.documentation`.
  String? get documentation => _text(node, 'documentation');

  /// `group.input`.
  List<InputView> get inputs => [
    for (final i in node.getChildrenByName('input')) InputView(i),
  ];

  /// `group.rule`.
  List<RuleView> get rules => [
    for (final r in node.getChildrenByName('rule')) RuleView(r),
  ];
}

/// A `group.input`.
class InputView {
  /// Wraps an input [node].
  const InputView(this.node);

  /// The input node itself.
  final FhirNode node;

  /// `input.name`.
  String? get name => _text(node, 'name');

  /// `input.type`.
  String? get type => _text(node, 'type');

  /// `input.mode` (`source`, `target`).
  String? get mode => _text(node, 'mode');

  /// `input.documentation`.
  String? get documentation => _text(node, 'documentation');
}

/// A `group.rule`.
class RuleView {
  /// Wraps a rule [node].
  const RuleView(this.node);

  /// The rule node itself.
  final FhirNode node;

  /// `rule.name`.
  String? get name => _text(node, 'name');

  /// `rule.documentation`.
  String? get documentation => _text(node, 'documentation');

  /// `rule.source`.
  List<SourceView> get sources => [
    for (final s in node.getChildrenByName('source')) SourceView(s),
  ];

  /// `rule.target`.
  List<TargetView> get targets => [
    for (final t in node.getChildrenByName('target')) TargetView(t),
  ];

  /// `rule.rule`, the nested rules.
  List<RuleView> get rules => [
    for (final r in node.getChildrenByName('rule')) RuleView(r),
  ];

  /// `rule.dependent`.
  List<DependentView> get dependents => [
    for (final d in node.getChildrenByName('dependent')) DependentView(d),
  ];
}

/// A `rule.source`.
class SourceView {
  /// Wraps a source [node].
  const SourceView(this.node);

  /// The source node itself.
  final FhirNode node;

  /// `source.context`, the variable the source is read from.
  String? get context => _text(node, 'context');

  /// `source.element`.
  String? get element => _text(node, 'element');

  /// `source.type`.
  String? get type => _text(node, 'type');

  /// `source.min`.
  String? get min => _text(node, 'min');

  /// `source.max`.
  String? get max => _text(node, 'max');

  /// `source.defaultValue[x]` (R4B) or `source.defaultValue` (R5), the
  /// value as a node.
  FhirNode? get defaultValue => node.getChildByName('defaultValue');

  /// `source.listMode` (`first`, `not_first`, `last`, `not_last`,
  /// `only_one`).
  String? get listMode => _text(node, 'listMode');

  /// `source.variable`.
  String? get variable => _text(node, 'variable');

  /// `source.condition`, the `where` FHIRPath.
  String? get condition => _text(node, 'condition');

  /// `source.check`, the `check` FHIRPath.
  String? get check => _text(node, 'check');

  /// `source.logMessage`, the `log` FHIRPath.
  String? get logMessage => _text(node, 'logMessage');
}

/// A `rule.target`.
class TargetView {
  /// Wraps a target [node].
  const TargetView(this.node);

  /// The target node itself.
  final FhirNode node;

  /// `target.context`, the variable the target is written into.
  String? get context => _text(node, 'context');

  /// `target.element`.
  String? get element => _text(node, 'element');

  /// `target.variable`.
  String? get variable => _text(node, 'variable');

  /// `target.transform` (`create`, `copy`, `evaluate`, ...).
  String? get transform => _text(node, 'transform');

  /// `target.listMode` values (`first`, `share`, `last`, `collate`).
  List<String> get listModes => _texts(node, 'listMode');

  /// `target.listRuleId`.
  String? get listRuleId => _text(node, 'listRuleId');

  /// `target.parameter`.
  List<ParameterView> get parameters => [
    for (final p in node.getChildrenByName('parameter')) ParameterView(p),
  ];
}

/// A `target.parameter` (and, in R5, a `dependent.parameter`).
class ParameterView {
  /// Wraps a parameter [node].
  const ParameterView(this.node);

  /// The parameter node itself.
  final FhirNode node;

  /// `parameter.value[x]`, the value as a node.
  FhirNode? get value => node.getChildByName('value');

  /// Whether the value is a variable reference: `valueId`.
  bool get isVariable => value?.hasType(['id']) ?? false;

  /// The value's type name (`id`, `string`, `boolean`, `integer`,
  /// `decimal`).
  String? get valueType => value?.fhirType;

  /// The value as text.
  String? get valueText => value?.primitiveValue;
}

/// A `rule.dependent`, the invocation of another group.
class DependentView {
  /// Wraps a dependent [node].
  const DependentView(this.node);

  /// The dependent node itself.
  final FhirNode node;

  /// `dependent.name`, the group invoked.
  String? get name => _text(node, 'name');

  /// The arguments: R4B's `dependent.variable` strings, or R5's
  /// `dependent.parameter` values, whichever the map carries.
  List<String> get arguments {
    final variables = _texts(node, 'variable');
    if (variables.isNotEmpty) return variables;
    return [
      for (final p in node.getChildrenByName('parameter'))
        if (ParameterView(p).valueText case final String v) v,
    ];
  }
}

/// A ConceptMap.
class ConceptMapView {
  /// Wraps a ConceptMap [node].
  const ConceptMapView(this.node);

  /// The ConceptMap itself.
  final FhirNode node;

  /// `ConceptMap.id`.
  String? get id => _text(node, 'id');

  /// `ConceptMap.group`.
  List<ConceptMapGroupView> get groups => [
    for (final g in node.getChildrenByName('group')) ConceptMapGroupView(g),
  ];
}

/// A `ConceptMap.group`.
class ConceptMapGroupView {
  /// Wraps a group [node].
  const ConceptMapGroupView(this.node);

  /// The group node itself.
  final FhirNode node;

  /// `group.source`, the source system.
  String? get source => _text(node, 'source');

  /// `group.target`, the target system.
  String? get target => _text(node, 'target');

  /// `group.unmapped.mode`, when given.
  String? get unmappedMode =>
      node.getChildByName('unmapped')?.getChildByName('mode')?.primitiveValue;

  /// `group.element`.
  List<ConceptMapElementView> get elements => [
    for (final e in node.getChildrenByName('element')) ConceptMapElementView(e),
  ];
}

/// A `group.element`.
class ConceptMapElementView {
  /// Wraps an element [node].
  const ConceptMapElementView(this.node);

  /// The element node itself.
  final FhirNode node;

  /// `element.code`.
  String? get code => _text(node, 'code');

  /// `element.target`.
  List<ConceptMapTargetView> get targets => [
    for (final t in node.getChildrenByName('target')) ConceptMapTargetView(t),
  ];
}

/// An `element.target`.
class ConceptMapTargetView {
  /// Wraps a target [node].
  const ConceptMapTargetView(this.node);

  /// The target node itself.
  final FhirNode node;

  /// `target.code`.
  String? get code => _text(node, 'code');

  /// How source and target relate: R4B's `equivalence` or R5's
  /// `relationship`, whichever the map carries.
  String? get relationship =>
      _text(node, 'equivalence') ?? _text(node, 'relationship');

  /// `target.comment`.
  String? get comment => _text(node, 'comment');
}
