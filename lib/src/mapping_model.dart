import 'package:fhir_mapping/src/node_builder.dart';
import 'package:fhir_node/fhir_node.dart';
import 'package:fhir_path/fhir_path.dart';

/// What the mapping engine and parser need from a FHIR version, supplied by
/// a binding (`fhir_r4_mapping`, `fhir_r5_mapping`, `fhir_r6_mapping`).
///
/// Beyond [ResourceModel] (version, resource type names, resources from and
/// to JSON): how to make the version's builders, how to turn a node into a
/// builder, the fhir_path binding the engine evaluates FHIRPath over, and
/// the few places where versions spell a StructureMap or ConceptMap
/// differently.
abstract class MappingModel<R extends FhirNode> extends ResourceModel<R> {
  /// Creates a model.
  const MappingModel();

  /// The fhir_path binding of this version, for FHIRPath evaluation.
  FhirModelBinding get pathBinding;

  /// An empty builder for [typeName] (`Patient`, `Coding`, `string`, or the
  /// builder spelling `CodingBuilder`), or null when the version has no
  /// such type.
  FhirNodeBuilder? createBuilder(String typeName);

  /// A primitive builder of [typeName] (`string`, `id`, `uri`, `code`,
  /// `integer`, `decimal`, `boolean`, `date`, `dateTime`, `instant`,
  /// `time`, `oid`, `base64Binary`, `canonical`, `url`, `unsignedInt`,
  /// `positiveInt`, `markdown`) holding [value].
  FhirNodeBuilder primitive(String typeName, Object value);

  /// A builder holding the same content as [node] (a resource or element of
  /// this version, or a FHIRPath result).
  FhirNodeBuilder toBuilder(FhirNode node);

  /// A builder for a resource or element from its JSON; [typeName] names
  /// the type when the JSON is not a resource (no `resourceType`).
  FhirNodeBuilder builderFromJson(
    Map<String, dynamic> json, [
    String? typeName,
  ]);

  /// A quoted rule name as this version's StructureMap carries it. R4B keeps
  /// it as written; R5 and R6 strip hyphens (the R5 reference parser's
  /// `fixName`, `c.replace("-", "")`, StructureMapUtilities.parseRule).
  String ruleName(String quoted) => quoted;

  /// The `group.typeMode` to write when the map text gives none: R4B
  /// requires the element (`none`); R5 and R6 leave it out (null).
  String? get groupTypeModeDefault => 'none';

  /// Whether the version's StructureMap target carries `contextType`
  /// (R4B: yes; R5 and R6 dropped it).
  bool get targetHasContextType => true;

  /// The JSON of a rule's `dependent` for the invocation of a group with
  /// [arguments]. R4B's `dependent.variable` is a list of strings; R5 and
  /// R6 moved to `dependent.parameter`, a list of parameters.
  Map<String, dynamic> dependentArguments(
    List<Map<String, dynamic>> arguments,
  ) => {
    'variable': [
      for (final a in arguments)
        a['valueId'] ?? a['valueString'] ?? a.values.first.toString(),
    ],
  };

  /// The JSON key of a source's default value: R4B's `defaultValue[x]` as
  /// a string is `defaultValueString`; R5 and R6 have `defaultValue`.
  String get sourceDefaultValueKey => 'defaultValueString';

  /// The element of a ConceptMap target that holds how source and target
  /// relate: R4B `equivalence`, R5 and R6 `relationship`.
  String get conceptMapRelationshipElement => 'equivalence';

  /// The ConceptMap relationship code for a map-language token (`=`, `==`,
  /// `!=`, `<=`, `>=`, `-`, and R4B's `--`, `<-`, `>-`, `~`), or null when
  /// the version has no such code.
  String? conceptMapRelationship(String token) => switch (token) {
    '-' => 'relatedto',
    '=' => 'equal',
    '==' => 'equivalent',
    '!=' => 'disjoint',
    '--' => 'unmatched',
    '<=' => 'wider',
    '<-' => 'subsumes',
    '>=' => 'narrower',
    '>-' => 'specializes',
    '~' => 'inexact',
    _ => null,
  };

  /// The relationship codes under which a translation counts as a match.
  Set<String> get matchingRelationships => const {
    'equal',
    'relatedto',
    'equivalent',
    'wider',
  };

  /// The `unmapped.mode` a ConceptMap declares with `unmapped for X =
  /// provided`: R4B `provided`, R5 and R6 `use-source-code`.
  String get unmappedProvidedMode => 'provided';
}
