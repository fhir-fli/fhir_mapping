import 'package:fhir_node/fhir_node.dart';
import 'package:fhir_path/fhir_path.dart';
import 'package:ucum/ucum.dart';

/// A minimal FhirNode over plain values/maps — enough for engine tests that
/// exercise the parser, lexer, and basic navigation without any FHIR model.
class StubNode implements FhirNode {
  StubNode(this.type, {this.value, this.children = const {}});

  final String type;
  final String? value;
  final Map<String, List<StubNode>> children;

  @override
  String get fhirType => type;

  @override
  bool get isPrimitive => value != null;

  @override
  bool get isResource => type.isNotEmpty && type[0] == type[0].toUpperCase();

  @override
  String? get primitiveValue => value;

  @override
  bool get isMetadataBased => false;

  @override
  bool hasType(List<String> names) =>
      names.any((n) => n.toLowerCase() == type.toLowerCase());

  @override
  bool isEmpty() => value == null && children.isEmpty;

  @override
  List<FhirNode> getChildrenByName(String name, [bool checkValid = false]) =>
      children[name] ?? const <StubNode>[];

  @override
  List<String> listChildrenNames() => children.keys.toList();

  @override
  FhirNode? getChildByName(String name) {
    final matches = getChildrenByName(name);
    if (matches.length > 1) {
      throw StateError('more than one child for $name');
    }
    return matches.isEmpty ? null : matches.first;
  }

  @override
  bool equalsDeep(covariant StubNode? other) =>
      other != null &&
      type == other.type &&
      value == other.value &&
      children.length == other.children.length;
}

/// Literal factory sufficient for parsing (literals are constructed at
/// parse time) and for simple boolean/string/number evaluation results.
class StubValueFactory implements IFhirValueFactory {
  StubNode _prim(String type, Object? value) =>
      StubNode(type, value: value?.toString());

  @override
  FhirNode boolean(bool? value, {bool disallowExtensions = true}) =>
      _prim('boolean', value);

  @override
  FhirNode string(String? value, {bool disallowExtensions = true}) =>
      _prim('string', value);

  @override
  FhirNode integer(num? value, {bool disallowExtensions = true}) =>
      _prim('integer', value);

  @override
  FhirNode decimal(num? value, {bool disallowExtensions = true}) =>
      _prim('decimal', value);

  @override
  FhirNode decimalFromString(String? value, {bool disallowExtensions = true}) =>
      _prim('decimal', value);

  @override
  FhirNode time(String? value, {bool disallowExtensions = true}) =>
      _prim('time', value);

  @override
  FhirNode dateTimeOfType(
    String? value,
    String type, {
    bool disallowExtensions = true,
  }) => _prim(type, value);

  @override
  FhirNode? tryDateTime(String? value) =>
      value == null ? null : _prim('dateTime', value);

  @override
  FhirNode? tryDate(String? value) =>
      value == null ? null : _prim('date', value);

  @override
  FhirNode? tryTime(String? value) =>
      value == null ? null : _prim('time', value);

  @override
  FhirNode todayFrom(DateTime instant) =>
      _prim('date', instant.toIso8601String().substring(0, 10));

  @override
  FhirNode nowFrom(DateTime instant) =>
      _prim('dateTime', instant.toIso8601String());

  @override
  FhirNode timeOfDayFrom(DateTime instant) =>
      _prim('time', instant.toIso8601String().substring(11));

  StubNode _quantity(
    String? valueString,
    String? unit,
    String? system,
    String? code,
  ) => StubNode(
    'Quantity',
    children: {
      if (valueString != null)
        'value': [StubNode('decimal', value: valueString)],
      if (unit != null) 'unit': [StubNode('string', value: unit)],
      if (system != null) 'system': [StubNode('uri', value: system)],
      if (code != null) 'code': [StubNode('code', value: code)],
    },
  );

  @override
  FhirNode quantity({
    num? value,
    String? unit,
    String? system,
    String? code,
    bool disallowExtensions = false,
  }) => _quantity(value?.toString(), unit, system, code);

  @override
  FhirNode quantityLiteral({String? value, String? unit, String? ucumCode}) =>
      _quantity(value, unit, null, ucumCode);

  @override
  FhirNode numericAbs(FhirNode number) => number;

  @override
  FhirNode quantityWithValue(FhirNode quantity, num? value) => quantity;

  @override
  FhirNode quantityWithValueString(FhirNode quantity, String? value) =>
      quantity;

  @override
  FhirNode classTypeInfo(FhirNode instance) =>
      StubNode('ClassInfo', value: instance.fhirType);
}

/// Worker context sufficient for FHIRPathEngine.create + parse: literals go
/// through [valueFactory]; the async model-metadata members are only hit by
/// type-aware evaluation and throw if reached.
class StubWorkerContext implements IWorkerContext {
  final StubValueFactory _factory = StubValueFactory();

  @override
  IFhirValueFactory get valueFactory => _factory;

  @override
  UcumService get ucumService => UcumService();

  @override
  String getVersion() => '4.0.1';

  @override
  String formatMessage(String theMessage, List<dynamic> theMessageArguments) =>
      '$theMessage $theMessageArguments';

  @override
  String formatMessagePlural(
    int? count,
    String theMessage,
    List<dynamic> theMessageArguments,
  ) => '$theMessage $theMessageArguments';

  // Engine initialization reads these two type-name lists.
  @override
  Future<List<String>> specializedTypeNames() async => const <String>[];

  @override
  Future<Set<String>> primitiveTypeNames() async => const <String>{
    'boolean',
    'string',
    'integer',
    'decimal',
    'date',
    'dateTime',
    'time',
    'code',
    'uri',
  };

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(
        'StubWorkerContext does not implement ${invocation.memberName} — '
        'this test only exercises parse/lex, not type-aware evaluation.',
      );
}
