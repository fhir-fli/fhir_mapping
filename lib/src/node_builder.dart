import 'package:fhir_node/fhir_node.dart';

/// The mutable side of the `fhir_node` contract: a node under construction
/// that the mapping engine reads by name, writes by name, and finally turns
/// into a resource.
///
/// Each FHIR version's generated builders (`PatientBuilder`, `CodingBuilder`,
/// ...) implement this through their hand-written base class, so the one
/// engine builds every version's data without naming a class of it.
abstract class FhirNodeBuilder {
  /// The FHIR type name of this node (`Patient`, `Coding`, `string`).
  String get fhirType;

  /// Whether this node is a primitive (carries a single scalar value).
  bool get isPrimitive;

  /// Whether this node is a resource.
  bool get isResource;

  /// The scalar value of a primitive node as a string, or `null`.
  String? get primitiveValue;

  /// Whether this node's [fhirType] matches any of [names]
  /// (case-insensitive).
  bool hasType(List<String> names);

  /// Whether this node has no value.
  bool isEmpty();

  /// The element names under which this node can have children.
  List<String> listChildrenNames();

  /// The children of this node under the element [name].
  List<FhirNodeBuilder> getChildrenByName(String name, [bool checkValid]);

  /// The single child under [name], or `null` (throws if more than one).
  FhirNodeBuilder? getChildByName(String name);

  /// Sets [child] under the element [name]: replaces a single-valued
  /// element, appends to a repeating one. Throws when [name] is not an
  /// element of this type or [child] is not of its type.
  void setChildByName(String name, covariant FhirNodeBuilder? child);

  /// The type names a child under [name] may have, as the version spells
  /// them for its builders (`CodingBuilder`), empty for an unknown name.
  List<String> typeByElementName(String name);

  /// Creates an empty child under [name].
  void createProperty(String name);

  /// This node as JSON.
  Map<String, dynamic> toJson();

  /// The finished, immutable node.
  FhirNode build();
}
