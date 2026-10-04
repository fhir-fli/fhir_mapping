import 'package:collection/collection.dart';
import 'package:fhir_mapping/src/map_views.dart';
import 'package:fhir_mapping/src/mapping_model.dart';
import 'package:fhir_mapping/src/mapping_variables.dart';
import 'package:fhir_node/fhir_node.dart';
import 'package:fhir_path/fhir_path.dart';

/// Manages the transformation context for mapping FHIR structures.
class TransformationContext {
  /// Creates a [TransformationContext] with a [resolver].
  TransformationContext(this.resolver);

  /// The resolver for fetching FHIR definitions.
  final DefinitionResolver resolver;

  /// The currently active structure definition.
  FhirNode? currentDefinition;

  /// Sets the structure definition by resolving [structureUrl].
  Future<void> setStructure(String structureUrl) async {
    currentDefinition = await resolver.resolve(structureUrl);
  }

  /// Searches within the structure.
  ///
  /// Placeholder method that should be implemented later.
  List<FhirNode> performSearch(String search) {
    return <FhirNode>[]; // Replace with actual search logic later
  }
}

/// Resolves structure definitions for FHIR mapping, through the fhir_path
/// worker context over the version's binding and the given cache.
class DefinitionResolver {
  /// Creates a [DefinitionResolver] over [cache] for [model]'s version.
  DefinitionResolver(ResourceCache cache, MappingModel<FhirNode> model)
    : worker = FhirWorkerContext(
        binding: model.pathBinding,
        resourceCache: cache,
      );

  /// The worker context: the cache, and the terminology operations.
  final FhirWorkerContext worker;

  /// Resolves a StructureDefinition from [structureUrl].
  Future<FhirNode?> resolve(String structureUrl) {
    return worker.resourceCache.getStructureDefinition(structureUrl);
  }

  /// Resolves a StructureDefinition by [type], through the map's `uses`
  /// aliases when it has one.
  Future<FhirNode?> resolveByType(String? type, MapView? map) async {
    if (type == null) {
      return null;
    }

    final sd = await worker.fetchTypeDefinition(type);
    if (sd != null && sd.fhirType == 'StructureDefinition') {
      return sd;
    }

    final structures = map?.structures ?? const <StructureView>[];
    final structure =
        structures.firstWhereOrNull(
          (s) => s.url == type || s.alias?.toLowerCase() == type.toLowerCase(),
        ) ??
        structures.firstWhereOrNull(
          (s) =>
              s.url?.toLowerCase().endsWith('/${type.toLowerCase()}') ?? false,
        );

    final resolved = await resolve(structure?.url ?? type);
    if (resolved != null) {
      await worker.resourceCache.saveCanonicalResource(resolved);
    }
    return resolved;
  }

  /// Resolves an ElementDefinition for [objectLocation].
  Future<ElementNode?> resolveElementDefinition(
    String? objectLocation,
    MapView? map,
  ) async {
    if (objectLocation == null) {
      return null;
    }

    final pathParts = objectLocation.split('.');
    final baseType = pathParts.first;
    final sd = await resolveByType(baseType, map);
    if (sd == null) {
      return null;
    }

    return _resolveElementDefinition(sd, pathParts, map);
  }

  Future<ElementNode?> _resolveElementDefinition(
    FhirNode sd,
    List<String> pathParts,
    MapView? map,
  ) async {
    final ed = _resolveElementDefinitionFromStructure(sd, pathParts.join('.'));
    if (ed != null) {
      return ed;
    }

    for (var i = pathParts.length; i > 0; i--) {
      final path = pathParts.sublist(0, i - 1).join('.');

      final ed = _resolveElementDefinitionFromStructure(sd, path);

      if (ed != null) {
        final nextType = ed.singleTypeCode ?? resolvePolymorphicType(ed, path);

        final sd = await resolveByType(nextType, map);
        if (sd != null) {
          return _resolveElementDefinition(
            sd,
            [nextType!, ...pathParts.sublist(i - 1)],
            map,
          );
        } else {
          return null;
        }
      }
    }
    return null;
  }

  /// Determines if [objectLocation] is a list.
  Future<bool> isElementAList(String? objectLocation, MapView? map) async {
    final elementDef = await resolveElementDefinition(objectLocation, map);
    return elementDef?.isCollection ?? false;
  }

  /// Gets possible types for an element at [objectLocation].
  Future<List<String>> typesForElement(
    String? objectLocation,
    MapView? map,
  ) async {
    if (objectLocation == null) return <String>[];
    final elementDef = await resolveElementDefinition(objectLocation, map);
    return elementDef?.types.map((t) => t.code).toList() ?? <String>[];
  }

  /// Fetches the canonical resource at [uri], or null.
  Future<FhirNode?> fetchResource(String uri) =>
      worker.resourceCache.getCanonicalResource(uri);

  /// Fetches the canonical resource at [uri] when it is of [type].
  Future<FhirNode?> fetchResourceOfType(String uri, String type) async {
    final r = await fetchResource(uri);
    return r != null && r.fhirType == type ? r : null;
  }

  ElementNode? _resolveElementDefinitionFromStructure(
    FhirNode? structureDef,
    String path,
  ) {
    if (structureDef == null) return null;

    for (final el in [
      ...?structureDef.getChildByName('snapshot')?.getChildrenByName('element'),
      ...?structureDef
          .getChildByName('differential')
          ?.getChildrenByName('element'),
    ]) {
      final node = ElementNode(el);
      final elPath = node.path;
      if (elPath == path) {
        return node;
      }
      // Handle polymorphic elements containing '[x]'
      if (elPath.contains('[x]')) {
        final polymorphicBase = elPath.split('[x]').first;
        if (path.startsWith(polymorphicBase)) {
          return node;
        }
      }
    }
    return null;
  }

  /// Determines whether the given source and target types match within a
  /// group: the provided [srcType] and [tgtType] against the group's
  /// input types, with the map's `uses` aliases resolved.
  Future<bool> matchesByType(
    MapView map,
    GroupView group,
    String? srcType,
    String? tgtType,
  ) async {
    final inputs = group.inputs;
    if (group.typeMode == 'none' || inputs.length != 2) {
      return false;
    }

    final byMode = {for (final i in inputs) i.mode: i.type};
    final resolvedSrcType = await _resolveType(map, srcType);
    final resolvedTgtType = await _resolveType(map, tgtType);

    return resolvedSrcType == byMode['source'] &&
        resolvedTgtType == byMode['target'];
  }

  Future<String?> _resolveType(MapView map, String? type) async {
    for (final structure in map.structures) {
      if (structure.alias != null && structure.alias == type) {
        final sd = await resolve(structure.url ?? '');
        return sd?.getChildByName('type')?.primitiveValue ?? type ?? '';
      }
    }
    if ((type?.startsWith('http://') ?? false) ||
        (type?.startsWith('https://') ?? false)) {
      return (await resolve(type!))?.getChildByName('type')?.primitiveValue ??
          type;
    }
    return type;
  }

  /// Expands a ValueSet to include all possible values.
  ValueSetExpansionOutcome expandVS(FhirNode? vs) {
    return ValueSetExpansionOutcome(vs);
  }

  /// Validates a code using the specified options.
  Future<ValidationResult?> validateCode(
    ValidationOptions options,
    String? system,
    String? version,
    String code,
    String? display,
  ) async {
    return worker.validateCode(options, system, version, code, display);
  }
}

/// Determines the specific type for a polymorphic FHIR element.
///
/// Some FHIR elements use `[x]` notation to indicate polymorphism, meaning
/// they can be of different types. This function resolves the correct type
/// based on the given [elementDef] and [path].
///
/// Returns the resolved type as a string, or `null` if no match is found.
String? resolvePolymorphicType(ElementNode elementDef, String path) {
  final edPath = elementDef.path;
  if (!edPath.endsWith('[x]')) return null;
  final polyMorphicBase =
      edPath.substring(0, edPath.length - 3).split('.').last;
  final finalPath = path.split('.').last;
  if (finalPath.contains(polyMorphicBase)) {
    final type = finalPath.substring(polyMorphicBase.length);
    if (elementDef.types.any((t) => t.code == type)) {
      return type;
    } else {
      return null;
    }
  } else {
    return null;
  }
}

/// Represents a resolved group within a StructureMap.
class ResolvedGroup {
  /// Constructs a [ResolvedGroup] with a [target] and an associated
  /// [targetMap].
  ResolvedGroup(this.target, this.targetMap);

  /// Creates an empty [ResolvedGroup] with no target mapping.
  ResolvedGroup.empty() : target = null, targetMap = null;

  /// The target group within the structure map.
  GroupView? target;

  /// The associated structure map for the target group.
  MapView? targetMap;
}

/// Manages the storage and retrieval of StructureMap instances.
class StructureMapService {
  /// List of available StructureMap instances.
  final List<FhirNode> _structureMaps = [];

  /// Adds a StructureMap to the list of available transformations.
  void addStructureMap(FhirNode structureMap) {
    _structureMaps.add(structureMap);
  }

  /// Retrieves a StructureMap by its canonical URL.
  MapView? getTransform(String canonicalUrl) {
    final map = _structureMaps.firstWhereOrNull(
      (map) => MapView(map).url == canonicalUrl,
    );
    return map == null ? null : MapView(map);
  }

  /// Lists all StructureMap instances that match the given
  /// [canonicalUrlTemplate].
  List<MapView> listTransforms(String canonicalUrlTemplate) {
    final pattern = RegExp('^${canonicalUrlTemplate.replaceAll('*', '.*')}\$');
    return _structureMaps
        .where((map) => pattern.hasMatch(MapView(map).url ?? ''))
        .map(MapView.new)
        .toList();
  }
}

/// Represents the context for a transformation operation.
class TransformContext {
  /// Creates a [TransformContext] with an [appInfo] object.
  TransformContext(this.appInfo);

  /// Creates a [TransformContext] with an [appInfo] object.
  final Object appInfo;
}

class Property {}

class PropertyWithType {
  PropertyWithType(
    this.path,
    this.baseProperty,
    this.profileProperty,
    this.types,
  );

  String path;
  Property baseProperty;
  Property? profileProperty;
  TypeDetails types;

  String summary() {
    return path;
  }
}

class VariableForProfiling {
  VariableForProfiling(this.mode, this.name, this.property);
  MappingVariableMode mode;
  String name;
  PropertyWithType property;

  String summary() {
    return '$name: ${property.summary()}';
  }
}

class VariablesForProfiling {
  VariablesForProfiling({required this.optional, required this.repeating});
  List<VariableForProfiling> list = <VariableForProfiling>[];
  bool optional;
  bool repeating;

  void addProperty(
    MappingVariableMode mode,
    String name,
    String path,
    Property property,
    TypeDetails types,
  ) {
    add(mode, name, PropertyWithType(path, property, null, types));
  }

  void addProperties(
    MappingVariableMode mode,
    String name,
    String path,
    Property baseProperty,
    Property profileProperty,
    TypeDetails types,
  ) {
    add(
      mode,
      name,
      PropertyWithType(path, baseProperty, profileProperty, types),
    );
  }

  void add(MappingVariableMode mode, String name, PropertyWithType property) {
    VariableForProfiling? vv;
    for (final v in list) {
      if ((v.mode == mode) && v.name == name) {
        vv = v;
      }
    }
    if (vv != null) list.remove(vv);
    list.add(VariableForProfiling(mode, name, property));
  }

  VariablesForProfiling copyWith({bool? optional, bool? repeating}) {
    final result = VariablesForProfiling(
      optional: optional ?? this.optional,
      repeating: repeating ?? this.repeating,
    );
    result.list.addAll(list);
    return result;
  }

  VariableForProfiling? get(MappingVariableMode? mode, String name) {
    if (mode == null) {
      for (final v in list) {
        if ((v.mode == MappingVariableMode.OUTPUT) && v.name == name) {
          return v;
        }
      }
      for (final v in list) {
        if ((v.mode == MappingVariableMode.INPUT) && v.name == name) {
          return v;
        }
      }
    }
    for (final v in list) {
      if ((v.mode == mode) && v.name == name) {
        return v;
      }
    }
    return null;
  }

  String summary() {
    final s = StringBuffer();
    final t = StringBuffer();
    for (final v in list) {
      if (v.mode == MappingVariableMode.INPUT) {
        s.write(', ${v.summary()}');
      } else {
        t.write(', ${v.summary()}');
      }
    }
    return 'source variables [$s], target variables [$t]';
  }
}
