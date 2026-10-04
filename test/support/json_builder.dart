import 'dart:convert';

import 'package:fhir_mapping/fhir_mapping.dart';
import 'package:fhir_node/fhir_node.dart';
import 'package:fhir_path/fhir_path.dart';

import 'json_stub.dart';

/// Element → type table for the stub: `'Patient.name': 'HumanName*'`, a
/// trailing `*` marking a repeating element. Every type's `id` is an `id`
/// and `extension` repeats.
const Map<String, String> stubElementTypes = {
  '*.id': 'id',
  '*.extension': 'Extension*',
  'Patient.active': 'boolean',
  'Patient.name': 'HumanName*',
  'Patient.gender': 'code',
  'Patient.birthDate': 'date',
  'Patient.telecom': 'ContactPoint*',
  'Patient.maritalStatus': 'CodeableConcept',
  'Patient.managingOrganization': 'Reference',
  'Patient.contained': 'Resource*',
  'HumanName.family': 'string',
  'HumanName.given': 'string*',
  'HumanName.use': 'code',
  'HumanName.text': 'string',
  'ContactPoint.system': 'code',
  'ContactPoint.value': 'string',
  'CodeableConcept.coding': 'Coding*',
  'CodeableConcept.text': 'string',
  'Coding.system': 'uri',
  'Coding.version': 'string',
  'Coding.code': 'code',
  'Coding.display': 'string',
  'Reference.reference': 'string',
  'Extension.url': 'uri',
  'Extension.value': 'string',
  'Observation.status': 'code',
  'Observation.code': 'CodeableConcept',
  'Observation.value': 'Quantity',
  'Observation.subject': 'Reference',
  'Observation.contained': 'Resource*',
  'Quantity.value': 'decimal',
  'Quantity.unit': 'string',
  'Bundle.type': 'code',
  'Bundle.entry': 'BundleEntry*',
  'BundleEntry.resource': 'Resource',
  'Parameters.parameter': 'ParametersParameter*',
  'ParametersParameter.name': 'string',
  'ParametersParameter.value': 'string',
};

const Set<String> _primitives = {
  'base64Binary', 'boolean', 'canonical', 'code', 'date', 'dateTime', //
  'decimal', 'id', 'instant', 'integer', 'integer64', 'markdown', 'oid',
  'positiveInt', 'string', 'time', 'unsignedInt', 'uri', 'url', 'uuid',
};

const Set<String> _resources = {
  'Patient',
  'Observation',
  'Bundle',
  'Parameters',
  'StructureMap',
  'ConceptMap',
  'OperationOutcome',
  'StructureDefinition',
  'ValueSet',
};

/// A [FhirNodeBuilder] over a JSON map (or a scalar for a primitive), typed
/// by [stubElementTypes]. Complex children share the parent's map, so a
/// write through a child is visible in the parent.
class JsonNodeBuilder implements FhirNodeBuilder {
  JsonNodeBuilder(this.fhirType, [Object? value])
    : value =
          value ??
          (_primitives.contains(fhirType)
              ? null
              : _resources.contains(fhirType)
              ? <String, dynamic>{'resourceType': fhirType}
              : <String, dynamic>{});

  /// A builder over a resource's JSON.
  /// A literal map from a test may be typed `Map<String, String>`; the
  /// builder writes any JSON value, so this takes a JSON-typed copy.
  factory JsonNodeBuilder.resource(Map<String, dynamic> json) =>
      JsonNodeBuilder(
        json['resourceType'] as String,
        jsonDecode(jsonEncode(json)),
      );

  @override
  final String fhirType;

  /// The map of a complex node, or the scalar of a primitive.
  Object? value;

  Map<String, dynamic> get _map => value! as Map<String, dynamic>;

  @override
  bool get isPrimitive => _primitives.contains(fhirType);

  @override
  bool get isResource => _resources.contains(fhirType);

  @override
  String? get primitiveValue => isPrimitive ? value?.toString() : null;

  @override
  bool hasType(List<String> names) =>
      names.any((n) => n.toLowerCase() == fhirType.toLowerCase());

  @override
  bool isEmpty() => value == null || (value is Map && _map.isEmpty);

  @override
  List<String> listChildrenNames() =>
      isPrimitive ? const [] : _map.keys.toList();

  String? _typeOf(String name) =>
      stubElementTypes['$fhirType.$name'] ?? stubElementTypes['*.$name'];

  @override
  List<String> typeByElementName(String name) {
    final t = _typeOf(name);
    return t == null ? const [] : [t.replaceAll('*', '')];
  }

  bool _repeats(String name) => _typeOf(name)?.endsWith('*') ?? false;

  @override
  List<FhirNodeBuilder> getChildrenByName(
    String name, [
    bool checkValid = false,
  ]) {
    if (isPrimitive) return const [];
    final v = _map[name];
    if (v == null) return const [];
    final type = typeByElementName(name).firstOrNull ?? name;
    JsonNodeBuilder wrap(Object? e) =>
        e is Map<String, dynamic> && e['resourceType'] is String
            ? JsonNodeBuilder(e['resourceType'] as String, e)
            : JsonNodeBuilder(type, e);
    if (v is List) return [for (final e in v) wrap(e)];
    return [wrap(v)];
  }

  @override
  FhirNodeBuilder? getChildByName(String name) {
    final all = getChildrenByName(name);
    if (all.length > 1) throw StateError('more than one child for $name');
    return all.isEmpty ? null : all.first;
  }

  @override
  void setChildByName(String name, covariant JsonNodeBuilder? child) {
    final type = typeByElementName(name).firstOrNull;
    if (type == null) {
      throw ArgumentError('$fhirType has no element $name');
    }
    var v = child?.value;
    if (child != null && _primitives.contains(type)) {
      // The generated builders take any primitive for a primitive element
      // and convert it by its text (`FhirBooleanBuilder.tryParse(
      // child.toString())`), so a string literal fills a code or a boolean.
      if (!child.isPrimitive) {
        throw ArgumentError(
          '$fhirType.$name takes a $type, not a ${child.fhirType}',
        );
      }
      final text = child.primitiveValue!;
      v = switch (type) {
        'boolean' => bool.parse(text),
        'integer' || 'positiveInt' || 'unsignedInt' => int.parse(text),
        'decimal' => num.parse(text),
        _ => text,
      };
    } else if (type != 'Resource' && child != null && !child.hasType([type])) {
      throw ArgumentError(
        '$fhirType.$name takes a $type, not a ${child.fhirType}',
      );
    }
    if (_repeats(name)) {
      final list = (_map[name] ??= <Object?>[]) as List;
      if (child != null) list.add(v);
    } else {
      _map[name] = v;
    }
  }

  @override
  void createProperty(String name) {
    final type = typeByElementName(name).first;
    setChildByName(name, JsonNodeBuilder(type));
  }

  @override
  Map<String, dynamic> toJson() => isPrimitive ? {'value': value} : _map;

  @override
  FhirNode build() => JsonNode(
    jsonDecode(jsonEncode(value)),
    fhirType,
    elementTypes: {
      for (final e in stubElementTypes.entries)
        e.key: e.value.replaceAll('*', ''),
    },
  );

  @override
  String toString() => '$fhirType ${jsonEncode(value)}';
}

/// A [MappingModel] over [JsonNode] and [JsonNodeBuilder], in R4B shape.
class StubMappingModel extends MappingModel<JsonNode> {
  const StubMappingModel();

  @override
  String get fhirVersion => '4.3.0';

  @override
  Set<String> get resourceTypeNames => _resources;

  @override
  JsonNode fromJson(Map<String, dynamic> json) => JsonNode.resource(
    json,
    elementTypes: {
      for (final e in stubElementTypes.entries)
        e.key: e.value.replaceAll('*', ''),
    },
  );

  @override
  Map<String, dynamic> toJson(JsonNode resource) => resource.json;

  @override
  FhirModelBinding get pathBinding => const StubBinding();

  @override
  FhirNodeBuilder? createBuilder(String typeName) {
    final name =
        typeName.endsWith('Builder')
            ? typeName.substring(0, typeName.length - 'Builder'.length)
            : typeName;
    final known =
        _primitives.contains(name) ||
        _resources.contains(name) ||
        stubElementTypes.keys.any((k) => k.startsWith('$name.'));
    return known ? JsonNodeBuilder(name) : null;
  }

  @override
  FhirNodeBuilder primitive(String typeName, Object value) =>
      JsonNodeBuilder(typeName, value);

  @override
  FhirNodeBuilder toBuilder(FhirNode node) {
    if (node is JsonNode) return JsonNodeBuilder(node.fhirType, node.value);
    if (node.isPrimitive) {
      return JsonNodeBuilder(node.fhirType, node.primitiveValue);
    }
    final json = <String, dynamic>{};
    for (final name in node.listChildrenNames()) {
      final kids = node.getChildrenByName(name);
      if (kids.isEmpty) continue;
      final values = [
        for (final k in kids) (toBuilder(k) as JsonNodeBuilder).value,
      ];
      json[name] = values.length == 1 ? values.first : values;
    }
    return JsonNodeBuilder(node.fhirType, json);
  }

  @override
  FhirNodeBuilder builderFromJson(
    Map<String, dynamic> json, [
    String? typeName,
  ]) => JsonNodeBuilder(typeName ?? json['resourceType'] as String, json);
}
