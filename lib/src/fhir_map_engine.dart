// ignore_for_file: lines_longer_than_80_chars
// ignore_for_file: omit_local_variable_types, constant_identifier_names

import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:fhir_mapping/src/definition_resolver.dart';
import 'package:fhir_mapping/src/exceptions.dart';
import 'package:fhir_mapping/src/host_services.dart';
import 'package:fhir_mapping/src/map_views.dart';
import 'package:fhir_mapping/src/mapping_model.dart';
import 'package:fhir_mapping/src/mapping_variables.dart';
import 'package:fhir_mapping/src/node_builder.dart';
import 'package:fhir_node/fhir_node.dart';
import 'package:fhir_path/fhir_path.dart';
import 'package:uuid/uuid.dart';

/// Runs [map] over [source] into [target] (or a new target of the group's
/// type) with a fresh engine over [model]'s version.
Future<FhirNode?> fhirMappingEngine(
  MappingModel<FhirNode> model,
  FhirNodeBuilder source,
  FhirNode map,
  ResourceCache cache,
  FhirNodeBuilder? target, [
  FhirNodeBuilder? Function(String)? extendedEmptyFromType,
]) async {
  final mapEngine = await FhirMapEngine.create(cache, model)
    ..extendedEmptyFromType = extendedEmptyFromType;
  final transform = await mapEngine.transformBuilder('', source, map, target);
  return transform;
}

/// The primitive type names whose values are numbers.
const _numberTypes = {
  'integer',
  'decimal',
  'positiveInt',
  'unsignedInt',
  'integer64',
};

/// The primitive type names whose values are dates or times.
const _dateTimeTypes = {'date', 'dateTime', 'instant', 'time'};

/// Whether [s] is an absolute URL: a scheme (`http`, `https`, `urn`, `file`,
/// or any lowercase token) followed by details with no space (RFC 5141).
/// The same test as the reference engine's `Utilities.isAbsoluteUrl`.
bool _isAbsoluteUrl(String s) {
  final colon = s.indexOf(':');
  if (colon < 0) return false;
  final scheme = s.substring(0, colon);
  final details = s.substring(colon + 1);
  final token = RegExp(r'^[a-z][a-z0-9_\-]*$').hasMatch(scheme);
  return (const ['http', 'https', 'urn', 'file'].contains(scheme) || token) &&
      details.isNotEmpty &&
      !details.contains(' ');
}

/// Whether a primitive of [type] carries its value as text (anything but a
/// number, a date or time, or a boolean).
bool _stringBased(String type) =>
    !_numberTypes.contains(type) &&
    !_dateTimeTypes.contains(type) &&
    type != 'boolean';

class FhirMapEngine {
  FhirMapEngine._(ResourceCache cache, this.model)
    : resolver = DefinitionResolver(cache, model) {
    context = TransformationContext(resolver);
    services = FHIRPathHostServices();
  }

  static Future<FhirMapEngine> create(
    ResourceCache cache,
    MappingModel<FhirNode> model,
  ) async {
    final engine = FhirMapEngine._(cache, model);
    engine.fpe = await FHIRPathEngine.create(
      FhirWorkerContext(binding: model.pathBinding, resourceCache: cache),
      engine.services,
    );
    return engine;
  }

  /// The version whose builders the transform produces.
  final MappingModel<FhirNode> model;
  final DefinitionResolver resolver;
  late final TransformationContext context;
  late final IEvaluationContext? services;
  FHIRPathEngine? fpe;
  int rules = 0;
  FhirNodeBuilder? Function(String)? extendedEmptyFromType;

  /// Maps and groups registered for `imports` resolution.
  final StructureMapService structureMapService = StructureMapService();

  /// Per-node scratch data: parsed expressions on a source or target,
  /// resolved groups on a group. The typed engine kept these as the
  /// builders' user data (whose setter returned a copy it discarded, so
  /// nothing was ever cached); they are keyed by node identity here.
  final Expando<Map<String, Object?>> _userData = Expando();

  Map<String, Object?> _data(FhirNode node) => _userData[node] ??= {};

  static const String MAP_WHERE_CHECK = 'map.where.check';
  static const String MAP_WHERE_LOG = 'map.where.log';
  static const String MAP_SEARCH_EXPRESSION = 'map.search.expression';
  static const String MAP_WHERE_EXPRESSION = 'map.where.expression';
  static const String MAP_EXPRESSION = 'map.transform.expression';

  Future<FhirNode> transformFromFhir(
    FhirNode sourceResource,
    FhirNode map,
    FhirNode? targetResource,
  ) async {
    return transform('', sourceResource, map, targetResource);
  }

  /// Main transform method
  Future<FhirNode> transform(
    Object appInfo,
    FhirNode source,
    FhirNode map,
    FhirNode? target,
  ) async {
    return transformBuilder(
      appInfo,
      model.toBuilder(source),
      map,
      target == null ? null : model.toBuilder(target),
    );
  }

  /// Main transform method
  Future<FhirNode> transformBuilder(
    Object appInfo,
    FhirNodeBuilder sourceBuilder,
    FhirNode map,
    FhirNodeBuilder? targetBuilder,
  ) async {
    final mapView = MapView(map);
    final context = TransformContext(appInfo);
    final g = mapView.groups.firstOrNull;
    if (g == null) {
      throw FhirMappingException(message: 'No group found');
    }

    final inputName = _getInputName(g, 'source', 'source');
    if (inputName == null) {
      throw MappingDefinitionException(message: 'No input name found');
    }

    final vars =
        MappingVariables()
          ..add(MappingVariableMode.INPUT, inputName, sourceBuilder);
    final String? targetName = _getInputName(g, 'target', 'target');
    if (targetName != null) {
      if (targetBuilder != null) {
        vars.add(MappingVariableMode.OUTPUT, targetName, targetBuilder);
      } else {
        final type = _getInputType(g, 'target');
        if (type != null) {
          final newTarget = model.createBuilder(type);
          if (newTarget != null) {
            vars.add(MappingVariableMode.OUTPUT, targetName, newTarget);
          } else {
            throw FhirMappingException(
              message: 'Unable to create target of type $type',
            );
          }
        } else {
          throw FhirMappingException(
            message: 'Not handled yet: creating a type of $type',
          );
        }
      }
    } else {
      throw FhirMappingException(message: 'No target name found');
    }

    try {
      await _executeGroup('', context, mapView, vars, g, true);
      final result = vars.getOutputVar(targetName);

      if (result == null) {
        throw FhirMappingException(message: 'No output found');
      }
      try {
        return result.build();
      } catch (e) {
        // `build()` is `Type.fromJson(toJson())`, and fromJson dereferences
        // the required elements. A map that never set one therefore fails
        // with a bare "Null check operator used on a null value", which names
        // neither the type nor the element and is useless to whoever wrote the
        // map. The builder's own JSON says what the map DID produce, so say
        // that instead: the missing element is the one the type requires and
        // this list lacks.
        final produced = result.toJson().keys.toList()..sort();
        throw FhirMappingException(
          message:
              'The map did not produce a valid ${result.fhirType}: '
              '$e. It set: ${produced.isEmpty ? 'nothing' : produced.join(', ')}. '
              'An element the type requires is missing from that list.',
        );
      }
    } on FhirMappingException catch (e, s) {
      return _createOutcome(e.message ?? e.toString(), s.toString());
    } on Exception catch (e, s) {
      return _createOutcome(e.toString(), s.toString());
    }
  }

  FhirNode _createOutcome(String message, String stack) => model.fromJson(
    errorOperationOutcomeJson(diagnostics: message, code: 'processing'),
  );

  String? _getInputType(GroupView g, String mode) {
    String? type;
    for (final inp in g.inputs) {
      if (inp.mode == mode) {
        if (type != null) {
          throw MappingDefinitionException(
            message: 'This engine does not support multiple source inputs',
          );
        } else {
          type = inp.type;
        }
      }
    }
    return type;
  }

  String? _getInputName(GroupView g, String mode, String? def) {
    String? name;
    for (final inp in g.inputs) {
      if (inp.mode == mode) {
        if (name != null) {
          throw MappingDefinitionException(
            message: 'This engine does not support multiple source inputs',
          );
        } else {
          name = inp.name;
        }
      }
    }
    return name ?? def;
  }

  Future<void> _executeGroup(
    String indent,
    TransformContext context,
    MapView? map,
    MappingVariables vars,
    GroupView? group,
    bool atRoot,
  ) async {
    // Resolve and execute extended group first if it exists
    final resolvedGroup =
        (group?.extends_ ?? '').isNotEmpty
            ? _resolveGroupReference(map, group, group!.extends_!)
            : null;
    if (resolvedGroup != null) {
      await _executeGroup(
        '$indent ',
        context,
        resolvedGroup.targetMap,
        vars,
        resolvedGroup.target,
        false,
      );
    }

    // Execute rules within the group
    for (final rule in group?.rules ?? <RuleView>[]) {
      await _executeRule('$indent  ', context, map, vars, group, rule, atRoot);
    }
  }

  Future<void> _executeRule(
    String indent,
    TransformContext context,
    MapView? map,
    MappingVariables vars,
    GroupView? group,
    RuleView rule,
    bool atRoot,
  ) async {
    // Ensure single source and create copy of variables
    final sources = rule.sources;
    if (sources.length != 1) {
      throw Exception('Rule "${rule.name}" has multiple sources.');
    }
    final srcVars = vars.copy();

    // Process rule sources and targets
    final source = await _processSource(
      rule.name ?? '',
      context,
      srcVars,
      sources.first,
      map?.url ?? '',
      indent,
    );

    final targets = rule.targets;
    final childRules = rule.rules;
    final dependents = rule.dependents;
    for (final MappingVariables v in source ?? <MappingVariables>[]) {
      for (final target in targets) {
        await _processTarget(
          rule.name ?? '',
          context,
          v,
          map,
          group,
          target,
          sources.first.variable ?? '',
          atRoot,
          vars,
        );
      }
      if (childRules.isNotEmpty) {
        for (final childrule in childRules) {
          await _executeRule(
            '$indent  ',
            context,
            map,
            v,
            group,
            childrule,
            false,
          );
        }
      } else if (dependents.isNotEmpty) {
        for (final dependent in dependents) {
          await _executeDependency(
            '$indent  ',
            context,
            map,
            v,
            group,
            dependent,
          );
        }
      } else if (sources.length == 1 &&
          sources.first.variable != null &&
          targets.length == 1 &&
          targets.first.variable != null &&
          targets.first.transform == 'create' &&
          targets.first.parameters.isEmpty) {
        final FhirNodeBuilder? src = v.get(
          MappingVariableMode.INPUT,
          sources.first.variable,
        );
        final FhirNodeBuilder? tgt = v.get(
          MappingVariableMode.OUTPUT,
          targets.first.variable,
        );
        if (src == null || tgt == null) {
          continue;
        }

        final String srcType = src.fhirType;
        final String tgtType = tgt.fhirType;
        final ResolvedGroup defGroup = await _resolveGroupByTypes(
          map,
          rule.name ?? '',
          group,
          srcType,
          tgtType,
        );
        final MappingVariables vdef = MappingVariables();
        final defInputs = defGroup.target!.inputs;
        final inputName = defInputs.elementAtOrNull(0)?.name;
        if (inputName == null) {
          throw MappingDefinitionException(message: 'No input name found');
        }
        final targetName = defInputs.elementAtOrNull(1)?.name;
        if (targetName == null) {
          throw MappingDefinitionException(message: 'No target name found');
        }
        vdef
          ..add(MappingVariableMode.INPUT, inputName, src)
          ..add(MappingVariableMode.OUTPUT, targetName, tgt);
        await _executeGroup(
          '$indent  ',
          context,
          defGroup.targetMap,
          vdef,
          defGroup.target,
          false,
        );
      }
    }
  }

  Future<void> _executeDependency(
    String indent,
    TransformContext context,
    MapView? map,
    MappingVariables vin,
    GroupView? group,
    DependentView dependent,
  ) async {
    final rg = _resolveGroupReference(map, group, dependent.name!);

    final inputs = rg.target!.inputs;
    final arguments = dependent.arguments;
    if (inputs.length != arguments.length) {
      throw FhirMappingException(
        message:
            "Rule '${dependent.name}' has ${inputs.length} but "
            'the invocation has ${arguments.length} variables',
      );
    }
    final MappingVariables v = MappingVariables();
    for (int i = 0; i < inputs.length; i++) {
      final input = inputs[i];
      final varVal = arguments[i];
      final mode =
          input.mode == 'source'
              ? MappingVariableMode.INPUT
              : MappingVariableMode.OUTPUT;
      var vv = vin.get(mode, varVal);
      if (vv == null && mode == MappingVariableMode.INPUT) {
        vv = vin.get(MappingVariableMode.OUTPUT, varVal);
      }
      if (vv == null) {
        throw FhirMappingException(
          message:
              "Rule '${dependent.name}' $mode variable '${input.name}' "
              "named '$varVal' has no value (vars = ${vin.summary()})",
        );
      }
      if (input.name != null) {
        v.add(mode, input.name!, vv);
      } else {
        throw FhirMappingException(
          message:
              "Rule '${dependent.name}' $mode variable '${input.name}' "
              "named '$varVal' has no name (vars = ${vin.summary()})",
        );
      }
    }
    await _executeGroup(
      '$indent  ',
      context,
      rg.targetMap,
      v,
      rg.target,
      false,
    );
  }

  Future<String> _determineTypeFromSourceType(
    MapView? map,
    GroupView? source,
    FhirNodeBuilder fhirBase,
    List<String> types,
  ) async {
    final String type = fhirBase.fhirType;

    final String kn = 'type^$type';
    final cache = source == null ? null : _data(source.node);
    if (cache?[kn] case final String cached) {
      return cached;
    }

    final ResolvedGroup res = ResolvedGroup(null, null);
    for (final grp in map?.groups ?? <GroupView>[]) {
      if (await _matchesByType(map, grp, type)) {
        if (res.targetMap == null) {
          res
            ..targetMap = map
            ..target = grp;
        } else {
          throw FhirMappingException(
            message:
                'Multiple possible matches looking for '
                "default rule for '$type'",
          );
        }
      }
    }
    if (res.targetMap != null) {
      final String result = await _getActualType(
        res.targetMap!,
        res.target!.inputs.firstOrNull?.type ?? '',
      );
      cache?[kn] = result;
      return result;
    }

    for (final imp in map?.imports ?? <String>[]) {
      final List<MapView> impMapList = _findMatchingMaps(imp);
      if (impMapList.isEmpty) {
        throw FhirMappingException(message: 'Unable to find map(s) for $imp');
      }
      for (final impMap in impMapList) {
        if (impMap.url != map!.url) {
          for (final grp in impMap.groups) {
            if (await _matchesByType(impMap, grp, type)) {
              if (res.targetMap == null) {
                res
                  ..targetMap = impMap
                  ..target = grp;
              } else {
                throw FhirMappingException(
                  message:
                      'Multiple possible matches for default rule for '
                      "'$type' in ${res.targetMap!.url} (${res.target!.name}) "
                      'and ${impMap.url} (${grp.name})',
                );
              }
            }
          }
        }
      }
    }
    if (res.target == null) {
      throw FhirMappingException(
        message:
            "No matches found for default rule for '$type' from ${map?.url}",
      );
    }
    final String result = await _getActualType(
      res.targetMap!,
      res.target!.inputs.firstOrNull?.type ?? '',
    );
    cache?[kn] = result;
    return result;
  }

  List<MapView> _findMatchingMaps(String canonicalUrlTemplate) {
    final seenUrls = <String>{};
    var result = <MapView>[];

    if (canonicalUrlTemplate.contains('*')) {
      result = structureMapService.listTransforms(canonicalUrlTemplate);
    } else {
      final sm = structureMapService.getTransform(canonicalUrlTemplate);
      if (sm != null) {
        result.add(sm);
      }
    }

    result.removeWhere((sm) => !seenUrls.add(sm.url ?? ''));
    return result;
  }

  Future<ResolvedGroup> _resolveGroupByTypes(
    MapView? map,
    String ruleid,
    GroupView? source,
    String srcType,
    String tgtType,
  ) async {
    final String kn = 'types^$srcType:$tgtType';
    final cache = source == null ? null : _data(source.node);
    if (cache?[kn] case final ResolvedGroup cached) {
      return cached;
    }

    final ResolvedGroup res = ResolvedGroup(null, null);
    for (final grp in map?.groups ?? <GroupView>[]) {
      if (await _matchesByType(map, grp, srcType, tgtType)) {
        if (res.targetMap == null) {
          res
            ..targetMap = map
            ..target = grp;
        } else {
          throw FhirMappingException(
            message:
                'Multiple possible matches looking for rule for '
                "'$srcType/$tgtType', from rule '$ruleid'",
          );
        }
      }
    }
    if (res.targetMap != null) {
      cache?[kn] = res;
      return res;
    }

    for (final imp in map?.imports ?? <String>[]) {
      final List<MapView> impMapList = _findMatchingMaps(imp);
      if (impMapList.isEmpty) {
        throw FhirMappingException(message: 'Unable to find map(s) for $imp');
      }
      for (final impMap in impMapList) {
        if (impMap.url != map!.url) {
          for (final grp in impMap.groups) {
            if (await _matchesByType(impMap, grp, srcType, tgtType)) {
              if (res.targetMap == null) {
                res
                  ..targetMap = impMap
                  ..target = grp;
              } else {
                throw FhirMappingException(
                  message:
                      'Multiple possible matches for rule for '
                      "'$srcType/$tgtType' in ${res.targetMap!.url} and "
                      "${impMap.url}, from rule '$ruleid'",
                );
              }
            }
          }
        }
      }
    }
    if (res.target == null) {
      throw FhirMappingException(
        message:
            "No matches found for rule for '$srcType to $tgtType' "
            "from ${map?.url}, from rule '$ruleid'",
      );
    }
    cache?[kn] = res;
    return res;
  }

  Future<bool> _matchesByType(
    MapView? map,
    GroupView grp,
    String srcType, [
    String? tgtType,
  ]) async {
    if (tgtType == null && grp.typeMode != 'type-and-types') {
      return false;
    }
    final inputs = grp.inputs;
    if (inputs.length != 2 ||
        inputs.first.mode != 'source' ||
        inputs[1].mode != 'target') {
      return false;
    }
    if (tgtType == null) {
      return _matchesType(map, srcType, inputs.first.type ?? '');
    }
    if (inputs.first.type == null || inputs[1].type == null) {
      return false;
    }
    return await _matchesType(map, srcType, inputs.first.type ?? '') &&
        await _matchesType(map, tgtType, inputs[1].type ?? '');
  }

  Future<bool> _matchesType(
    MapView? map,
    String actualType,
    String statedType,
  ) async {
    var newStatedType = statedType;
    var newActualType = actualType;
    // check the aliases
    for (final imp in map?.structures ?? <StructureView>[]) {
      if (imp.alias != null && newStatedType == imp.alias) {
        // If we can fetch the underlying StructureDefinition
        final sd = await resolver.resolve(imp.url ?? '');
        if (sd != null) {
          newStatedType = sd.getChildByName('type')?.primitiveValue ?? '';
        }
        break;
      }
    }

    if (_isAbsoluteUrl(newActualType)) {
      final sd = await resolver.resolve(newActualType);
      if (sd != null) {
        newActualType = sd.getChildByName('type')?.primitiveValue ?? '';
      }
    }
    if (_isAbsoluteUrl(newStatedType)) {
      final sd = await resolver.resolve(newStatedType);
      if (sd != null) {
        newStatedType = sd.getChildByName('type')?.primitiveValue ?? '';
      }
    }
    return newActualType == newStatedType;
  }

  Future<String> _getActualType(MapView map, String statedType) async {
    // check the aliases
    for (final imp in map.structures) {
      if (imp.alias != null && statedType == imp.alias) {
        final sd = await resolver.resolve(imp.url ?? '');
        if (sd == null) {
          throw FhirMappingException(
            message: 'Unable to resolve structure ${imp.url}',
          );
        }
        // Should be sd.type, but R2 example used sd.id
        return sd.getChildByName('id')?.primitiveValue ?? statedType;
      }
    }
    return statedType;
  }

  ResolvedGroup _resolveGroupReference(
    MapView? map,
    GroupView? source,
    String name,
  ) {
    final String kn = 'ref^$name';
    final cache = source == null ? null : _data(source.node);
    if (cache?[kn] case final ResolvedGroup cached) {
      return cached;
    }

    final ResolvedGroup res = ResolvedGroup(null, null);
    for (final grp in map?.groups ?? <GroupView>[]) {
      if (grp.name == name) {
        if (res.targetMap == null) {
          res
            ..targetMap = map
            ..target = grp;
        } else {
          throw FhirMappingException(
            message: 'Multiple possible matches for rule "$name"',
          );
        }
      }
    }
    if (res.targetMap != null) {
      cache?[kn] = res;
      return res;
    }

    for (final imp in map?.imports ?? <String>[]) {
      final List<MapView> impMapList = _findMatchingMaps(imp);
      if (impMapList.isEmpty) {
        throw FhirMappingException(message: 'Unable to find map(s) for $imp');
      }
      for (final impMap in impMapList) {
        if (impMap.url != map!.url) {
          for (final grp in impMap.groups) {
            if (grp.name == name) {
              if (res.targetMap == null) {
                res
                  ..targetMap = impMap
                  ..target = grp;
              } else {
                throw FhirMappingException(
                  message:
                      'Multiple possible matches for rule group "$name" in '
                      '${res.targetMap!.url}#${res.target!.name} '
                      'and ${impMap.url}#${grp.name}',
                );
              }
            }
          }
        }
      }
    }
    if (res.target == null) {
      throw FhirMappingException(
        message:
            'No matches found for rule "$name". Reference found in ${map?.url}',
      );
    }
    cache?[kn] = res;
    return res;
  }

  /// The parsed FHIRPath for [expression] under [key] on [node], parsed
  /// once.
  ExpressionNode? _expression(FhirNode node, String key, String? expression) {
    final data = _data(node);
    if (data[key] case final ExpressionNode cached) return cached;
    final parsed = fpe?.parse(expression ?? '');
    data[key] = parsed;
    return parsed;
  }

  Future<List<MappingVariables>?> _processSource(
    String ruleId,
    TransformContext context,
    MappingVariables vars,
    SourceView src,
    String? pathForErrors,
    String indent,
  ) async {
    final List<FhirNodeBuilder> items = <FhirNodeBuilder>[];
    if (src.context == '@search') {
      // Evaluate an expression, then do a search
      _expression(src.node, MAP_SEARCH_EXPRESSION, src.element);
      // TODO(Dokotela): implement services
      // final String search =
      //     fpe.evaluateToString(vars, null, null, ''.toFhirString, expr);

      // items = services.performSearch(context.appInfo, search);
      throw FhirMappingException(message: 'Search not implemented');
    } else {
      final FhirNodeBuilder? b = vars.get(
        MappingVariableMode.INPUT,
        src.context,
      );

      if (b == null) {
        throw FhirMappingException(
          message:
              'Unknown input variable ${src.context} in $pathForErrors '
              'rule $ruleId (vars = ${vars.summary()})',
        );
      }

      if (src.element == null) {
        items.add(b);
      } else {
        await _getChildrenByName(b, src.element ?? '', items);

        final defaultValue = src.defaultValue;
        if (items.isEmpty && defaultValue != null) {
          items.add(model.toBuilder(defaultValue));
        }
      }
    }

    if (src.type != null) {
      items.removeWhere((item) => !_isType(item, src.type!));
    }

    if (src.condition != null) {
      final expr = _expression(src.node, MAP_WHERE_EXPRESSION, src.condition);

      final List<FhirNodeBuilder> remove = <FhirNodeBuilder>[];
      for (final item in items) {
        final MappingVariables varsForSource = vars.copy();
        if (src.variable != null) {
          varsForSource.add(MappingVariableMode.INPUT, src.variable!, item);
        }
        final srcBase = vars.get(MappingVariableMode.INPUT, src.context);
        final children = srcBase?.listChildrenNames();
        for (final child in children ?? <String>[]) {
          final varBase = vars.get(MappingVariableMode.INPUT, child);
          if (varBase == null) {
            final childItem = srcBase!.getChildrenByName(child);

            if (childItem.length == 1) {
              varsForSource.add(
                MappingVariableMode.INPUT,
                child,
                childItem.first,
              );
            }
          }
        }

        final bool passed =
            await fpe?.evaluateToBoolean(
              varsForSource,
              null,
              null,
              item.build(),
              expr!,
            ) ??
            false;

        if (!passed) {
          remove.add(item);
        }
      }
      remove.forEach(items.remove);
    }

    if (src.check != null) {
      final expr = _expression(src.node, MAP_WHERE_CHECK, src.check);
      for (final item in items) {
        final MappingVariables varsForSource = vars.copy();
        if (src.variable != null) {
          varsForSource.add(MappingVariableMode.INPUT, src.variable!, item);
        }
        final srcBase = vars.get(MappingVariableMode.INPUT, src.context);
        final children = srcBase?.listChildrenNames();
        for (final child in children ?? <String>[]) {
          final varBase = vars.get(MappingVariableMode.INPUT, child);
          if (varBase == null) {
            final childItem = srcBase!.getChildrenByName(child);

            if (childItem.length == 1) {
              varsForSource.add(
                MappingVariableMode.INPUT,
                child,
                childItem.first,
              );
            }
          }
        }
        final bool passed =
            await fpe?.evaluateToBoolean(
              varsForSource,
              null,
              null,
              item.build(),
              expr!,
            ) ??
            false;
        if (!passed) {
          throw FhirMappingException(
            message: "Rule '$ruleId', Check condition failed, $expr",
          );
        }
      }
    }

    if (src.logMessage != null) {
      final expr = _expression(src.node, MAP_WHERE_LOG, src.logMessage);
      final List<String> logs = <String>[];
      for (final item in items) {
        final MappingVariables varsForSource = vars.copy();
        if (src.variable != null) {
          varsForSource.add(MappingVariableMode.INPUT, src.variable!, item);
        }
        logs.add(
          (await fpe?.evaluateToString(
                varsForSource,
                null,
                null,
                item.build(),
                expr!,
              )) ??
              '',
        );
      }
      // TODO(Dokotela): implement services
      // if (logs.isNotEmpty && services != null) {
      //   services!.log(logs.join(', '));
      // }
    }

    if (src.listMode != null && items.isNotEmpty) {
      switch (src.listMode) {
        case 'first':
          final bt = items.first;
          items
            ..clear()
            ..add(bt);
        case 'not_first':
          if (items.isNotEmpty) {
            items.removeAt(0);
          }
        case 'last':
          final bt = items.last;
          items
            ..clear()
            ..add(bt);
        case 'not_last':
          if (items.isNotEmpty) {
            items.removeLast();
          }
        case 'only_one':
          if (items.length > 1) {
            throw FhirMappingException(
              message:
                  'Rule "$ruleId": Check condition failed: '
                  'the collection has more than one item',
            );
          }
        default:
          // no-op
          break;
      }
    }

    final List<MappingVariables> result = <MappingVariables>[];
    for (final r in items) {
      final MappingVariables v = vars.copy();
      if (src.variable != null) {
        v.add(MappingVariableMode.INPUT, src.variable!, r);
      }
      result.add(v);
    }
    return result;
  }

  bool _isType(FhirNodeBuilder item, String type) {
    return type == item.fhirType;
  }

  Future<void> _getChildrenByName(
    FhirNodeBuilder parentNode,
    String? elementName,
    List<FhirNodeBuilder> resultItems,
  ) async {
    if (elementName != null) {
      final children = parentNode.getChildrenByName(elementName);
      resultItems.addAll(children);
    }
  }

  Future<void> _processTarget(
    String rulePath,
    TransformContext context,
    MappingVariables vars,
    MapView? map,
    GroupView? group,
    TargetView tgt,
    String? srcVar,
    bool atRoot,
    MappingVariables sharedVars,
  ) async {
    FhirNodeBuilder? dest;
    if (tgt.context != null) {
      dest = vars.get(MappingVariableMode.OUTPUT, tgt.context);
      if (dest == null) {
        throw FhirMappingException(
          message: 'Rule "$rulePath": target context not known: ${tgt.context}',
        );
      }
      if (tgt.element == null) {
        throw FhirMappingException(
          message: 'Rule "$rulePath": Not supported yet',
        );
      }
    }
    FhirNodeBuilder? v;

    if (tgt.transform != null) {
      v = await _runTransform(
        rulePath,
        context,
        map,
        group,
        tgt,
        vars,
        dest,
        tgt.element ?? '',
        srcVar,
        atRoot,
      );

      if (v != null && dest != null) {
        try {
          dest.setChildByName(tgt.element!, v);
        } catch (e) {
          throw FhirMappingException(
            message:
                'Error setting ${tgt.element} on ${dest.fhirType} '
                'for rule $rulePath to value $v: $e',
          );
        }
      }
    } else if (dest != null) {
      if (tgt.listModes.contains('share')) {
        v = sharedVars.get(MappingVariableMode.SHARED, tgt.listRuleId);
        if (v == null) {
          final types = dest.typeByElementName(tgt.element!);
          if (types.isNotEmpty) {
            v = _typeFactory(types.first);
            dest.setChildByName(tgt.element!, v);
          }
          if (tgt.listRuleId != null && v != null) {
            sharedVars.add(MappingVariableMode.SHARED, tgt.listRuleId!, v);
          }
        }
      } else {
        final types = dest.typeByElementName(tgt.element!);
        if (types.isNotEmpty) {
          v = _typeFactory(types.first);
          dest.setChildByName(tgt.element!, v);
        }
      }
    }

    if (tgt.variable != null && v != null) {
      vars.add(MappingVariableMode.OUTPUT, tgt.variable!, v);
    }
  }

  /// A string primitive, the version's `string` builder.
  FhirNodeBuilder _string(String value) => model.primitive('string', value);

  Future<FhirNodeBuilder?> _runTransform(
    String rulePath,
    TransformContext context,
    MapView? map,
    GroupView? group,
    TargetView tgt,
    MappingVariables vars,
    FhirNodeBuilder? dest,
    String element,
    String? srcVar,
    bool root,
  ) async {
    final parameters = tgt.parameters;
    try {
      switch (tgt.transform) {
        case 'create':
          {
            String tn;
            if (parameters.isEmpty) {
              // must figure out type
              List<String> types = <String>[];

              if (dest != null) {
                types = dest.typeByElementName(element);
              }

              if (types.length == 1 &&
                  types[0] != '*' &&
                  types[0] != 'Resource') {
                tn = types[0];
              } else if (srcVar != null) {
                final FhirNodeBuilder? srcObj = vars.get(
                  MappingVariableMode.INPUT,
                  srcVar,
                );
                if (srcObj != null) {
                  tn = await _determineTypeFromSourceType(
                    map,
                    group,
                    srcObj,
                    types,
                  );
                } else {
                  throw FhirMappingException(
                    message:
                        'Cannot determine type from source variable: $srcVar',
                  );
                }
              } else {
                throw FhirMappingException(
                  message:
                      'Cannot determine type implicitly because there is '
                      'no single input variable',
                );
              }
            } else {
              tn = _getParamStringNoNull(
                vars,
                parameters.first,
                tgt.node.toString(),
              );
              // attempt to resolve alias in map's structure
              for (final uses in map?.structures ?? <StructureView>[]) {
                if (uses.mode == 'target' &&
                    uses.alias != null &&
                    tn == uses.alias) {
                  tn = uses.url ?? '';
                  break;
                }
              }
            }

            final createdObject = _typeFactory(tn);
            if (createdObject.isResource &&
                createdObject.fhirType != 'Parameters') {
              final idTypes = createdObject.typeByElementName('id');
              createdObject.setChildByName(
                'id',
                model.primitive(
                  idTypes.isEmpty ? 'string' : idTypes.first,
                  const Uuid().v4(),
                ),
              );
            }
            return createdObject;
          }

        case 'copy':
          {
            if (parameters.isEmpty) {
              throw FhirMappingException(
                message:
                    'Rule "$rulePath": Transform COPY requires a parameter',
              );
            }
            return _getParam(vars, parameters.first);
          }

        case 'evaluate':
          {
            ExpressionNode? expr =
                _data(tgt.node)[MAP_EXPRESSION] as ExpressionNode?;
            if (expr == null && parameters.isNotEmpty) {
              expr = fpe?.parse(
                _getParamStringNoNull(
                  vars,
                  parameters.last,
                  tgt.node.toString(),
                ),
              );
              _data(tgt.node)[MAP_EXPRESSION] = expr;
            }
            final FhirNodeBuilder test =
                parameters.length == 2
                    ? (_getParam(vars, parameters.first) ??
                        model.primitive('boolean', false))
                    : model.primitive('boolean', false);
            final List<FhirNode> v =
                expr == null
                    ? <FhirNode>[]
                    : (await fpe?.evaluateWithContext(
                          vars,
                          null,
                          null,
                          test.build(),
                          expr,
                        )) ??
                        <FhirNode>[];
            if (v.isEmpty) {
              return null;
            } else if (v.length != 1) {
              throw FhirMappingException(
                message:
                    'Rule "$rulePath": '
                    'Evaluation of $expr returned ${v.length} objects',
              );
            } else {
              return model.toBuilder(v.first);
            }
          }

        case 'truncate':
          {
            if (parameters.length == 2) {
              String src = _getParamString(vars, parameters[0]) ?? '';
              if (_numberTypes.contains(parameters[1].valueType)) {
                final int? l =
                    num.tryParse(parameters[1].valueText ?? '')?.toInt();
                if (l == null) {
                  throw FhirMappingException(
                    message:
                        'Rule "$rulePath": Transform TRUNCATE requires a '
                        'number as the second parameter',
                  );
                }
                if (src.length > l) {
                  src = src.substring(0, l);
                }
                return _string(src);
              } else {
                final String len = _getParamStringNoNull(
                  vars,
                  parameters[1],
                  tgt.node.toString(),
                );
                if (int.tryParse(len) != null) {
                  final int l = int.parse(len);
                  if (src.length > l) {
                    src = src.substring(0, l);
                  }
                }
                return _string(src);
              }
            } else {
              throw FhirMappingException(
                message:
                    'Rule "$rulePath": '
                    'Transform TRUNCATE requires two parameters',
              );
            }
          }

        case 'escape':
          {
            if (parameters.length < 3) {
              throw FhirMappingException(
                message:
                    'Escape transform requires source, '
                    'fmt1, and fmt2 parameters',
              );
            }

            final sourceNode = _getParam(vars, parameters[0]);
            final fmt1 =
                _getParamStringGeneral(
                  vars,
                  parameters[1],
                  map,
                  throwIfNull: true,
                )!;
            final fmt2 =
                _getParamStringGeneral(
                  vars,
                  parameters[2],
                  map,
                  throwIfNull: true,
                )!;

            if (sourceNode == null ||
                !sourceNode.isPrimitive ||
                !_stringBased(sourceNode.fhirType) ||
                sourceNode.primitiveValue == null) {
              throw FhirMappingException(
                message:
                    'Source for escape must be a string primitive with '
                    'a valid string value',
              );
            }

            final sourceString = sourceNode.primitiveValue;
            String resultString;

            // Handle escaping transformations between formats
            resultString = _convertEscaping(sourceString!, fmt1, fmt2);

            return _string(resultString);
          }

        case 'cast':
          {
            final String src =
                parameters.isEmpty
                    ? ''
                    : _getParamString(vars, parameters.first) ?? '';
            if (parameters.length == 1) {
              throw FhirMappingException(
                message: 'Implicit type parameters on cast not yet supported',
              );
            }
            final String t = _getParamString(vars, parameters[1]) ?? '';

            try {
              switch (t.toLowerCase()) {
                case 'string':
                case 'fhirstring':
                case 'fhir.string':
                  return _string(src);

                case 'integer':
                case 'fhirinteger':
                case 'fhir.integer':
                  return _castToInt(src, rulePath, t);

                case 'boolean':
                case 'fhirboolean':
                case 'fhir.boolean':
                  return model.primitive(
                    'boolean',
                    src.toLowerCase() == 'true',
                  );

                case 'decimal':
                case 'fhirdecimal':
                case 'fhir.decimal':
                  return model.primitive('decimal', double.parse(src));

                case 'date':
                case 'fhirdate':
                case 'fhir.date':
                  return model.primitive('date', src);

                case 'datetime':
                case 'fhirdatetime':
                case 'fhir.datetime':
                  return model.primitive('dateTime', src);

                case 'time':
                case 'fhirtime':
                case 'fhir.time':
                  return model.primitive('time', src);

                case 'instant':
                case 'fhirinstant':
                case 'fhir.instant':
                  return model.primitive('instant', src);

                case 'uri':
                case 'fhiruri':
                case 'fhir.uri':
                  return model.primitive('uri', src);

                case 'oid':
                case 'fhiroid':
                case 'fhir.oid':
                  return model.primitive('oid', src);

                case 'id':
                case 'fhirid':
                case 'fhir.id':
                  return model.primitive('id', src);

                case 'base64binary':
                case 'fhirbase64binary':
                case 'fhir.base64binary':
                  return model.primitive('base64Binary', src);

                case 'code':
                case 'fhircode':
                case 'fhir.code':
                case 'fhircodeenum':
                  return model.primitive('code', src);

                case 'canonical':
                case 'fhircanonical':
                case 'fhir.canonical':
                  return model.primitive('canonical', src);

                case 'url':
                case 'fhirurl':
                case 'fhir.url':
                  return model.primitive('url', src);

                case 'unsignedint':
                case 'fhirunsignedint':
                case 'fhir.unsignedint':
                  return model.primitive('unsignedInt', int.parse(src));

                case 'positiveint':
                case 'fhirpositiveint':
                case 'fhir.positiveint':
                  final intValue = int.parse(src);
                  if (intValue <= 0) {
                    throw FHIRMappingCastException(
                      message:
                          "Rule '$rulePath': "
                          'PositiveInt must be greater than zero.',
                    );
                  }
                  return model.primitive('positiveInt', intValue);

                case 'markdown':
                case 'fhirmarkdown':
                case 'fhir.markdown':
                  return model.primitive('markdown', src);

                default:
                  throw FHIRMappingCastException(
                    message: "Rule '$rulePath': Unsupported cast to type '$t'.",
                  );
              }
            } catch (e) {
              if (e is FHIRMappingCastException) {
                rethrow;
              } else {
                throw FHIRMappingCastException(
                  message:
                      "Rule '$rulePath': Failed to cast '$src' to type "
                      "'$t'. $e",
                );
              }
            }
          }

        case 'append':
          {
            if (parameters.isEmpty) {
              throw FhirMappingException(
                message: 'Append transform requires a source parameter',
              );
            }

            final StringBuffer sb = StringBuffer(
              _getParamString(vars, parameters.first) ?? '',
            );
            for (int i = 1; i < parameters.length; i++) {
              sb.write(_getParamString(vars, parameters[i]) ?? '');
            }
            return _string(sb.toString());
          }

        case 'translate':
          {
            return await _translate(context, map, vars, parameters);
          }

        case 'reference':
          {
            if (parameters.isEmpty) {
              throw FhirMappingException(
                message: 'Reference transform requires a source parameter',
              );
            }
            final FhirNodeBuilder? b = _getParam(vars, parameters.first);
            if (b == null) {
              throw FhirMappingException(
                message:
                    'Rule "$rulePath": Unable to find parameter '
                    '${parameters.first.valueText}',
              );
            }
            if (!b.isResource) {
              throw FhirMappingException(
                message:
                    'Rule "$rulePath": Transform engine cannot point at an '
                    'element of type ${b.fhirType}',
              );
            } else {
              return _string(_resourcePath(b));
            }
          }

        case 'dateOp':
          {
            if (parameters.length < 2) {
              throw FhirMappingException(
                message:
                    'dateOp transform requires a source date and an '
                    'operation parameter',
              );
            }

            final sourceNode = _getParam(vars, parameters[0]);
            final operation =
                _getParamStringGeneral(
                  vars,
                  parameters[1],
                  map,
                  throwIfNull: true,
                )!;

            if (sourceNode == null ||
                !sourceNode.isPrimitive ||
                !_stringBased(sourceNode.fhirType) ||
                sourceNode.primitiveValue == null) {
              throw FhirMappingException(
                message:
                    'Source for dateOp must be a string LeafNode '
                    'representing a date',
              );
            }

            final sourceDateStr = sourceNode.primitiveValue!;
            final sourceDate = DateTime.parse(sourceDateStr);
            DateTime resultDate;

            // Example operation: add days
            if (operation.startsWith('addDays(')) {
              final daysStr = operation.substring(8, operation.length - 1);
              final days = int.parse(daysStr);
              resultDate = sourceDate.add(Duration(days: days));
            } else {
              throw FhirMappingException(
                message: 'Unsupported date operation: $operation',
              );
            }

            return _string(resultDate.toIso8601String());
          }

        case 'uuid':
          {
            return model.primitive('id', const Uuid().v4());
          }

        case 'pointer':
          {
            if (parameters.isEmpty) {
              throw FhirMappingException(
                message: 'Pointer transform requires a source parameter',
              );
            }
            final FhirNodeBuilder? b = _getParam(vars, parameters.first);
            if (b != null && b.isResource) {
              return model.primitive(
                'uri',
                'urn:uuid:${b.getChildByName('id')?.primitiveValue}',
              );
            } else {
              throw FhirMappingException(
                message:
                    'Rule "$rulePath": Transform engine cannot point at an '
                    'element of type ${b?.fhirType}',
              );
            }
          }

        case 'cc':
          {
            if (parameters.length < 2) {
              throw FhirMappingException(
                message: 'cc transform requires two parameters',
              );
            }
            final String uri = _getParamStringNoNull(
              vars,
              parameters.first,
              tgt.node.toString(),
            );
            final String code = _getParamStringNoNull(
              vars,
              parameters[1],
              tgt.node.toString(),
            );
            final FhirNodeBuilder c = await _buildCoding(uri, code);
            return _typeFactory('CodeableConcept')..setChildByName('coding', c);
          }

        case 'c':
          {
            if (parameters.length < 2) {
              throw FhirMappingException(
                message: 'c transform requires two parameters',
              );
            }
            final String uri = _getParamStringNoNull(
              vars,
              parameters.first,
              tgt.node.toString(),
            );
            final String code = _getParamStringNoNull(
              vars,
              parameters[1],
              tgt.node.toString(),
            );
            return await _buildCoding(uri, code);
          }

        default:
          {
            throw FhirMappingException(
              message: 'Rule "$rulePath": Transform Unknown: ${tgt.transform}',
            );
          }
      }
    } catch (e) {
      throw e is FhirMappingException
          ? e
          : FhirMappingException(
            message:
                'Exception executing transform ${jsonEncode(_nodeJson(tgt.node))} on Rule '
                '"$rulePath": $e',
            cause: e is Exception ? e : null,
          );
    }
  }

  /// The JSON of a node of the map, for messages: the model's when it can
  /// give it, else the type name.
  Object _nodeJson(FhirNode node) {
    try {
      return model.toJson(node);
    } on Object catch (_) {
      return node.fhirType;
    }
  }

  /// `Type/id` of a resource builder.
  String _resourcePath(FhirNodeBuilder b) =>
      '${b.fhirType}/${b.getChildByName('id')?.primitiveValue}';

  FhirNodeBuilder _typeFactory(String tn) {
    FhirNodeBuilder? newObject;
    if (extendedEmptyFromType != null) {
      newObject = extendedEmptyFromType!(tn);
      if (newObject != null) {
        return newObject;
      }
    }

    newObject = model.createBuilder(tn);
    if (newObject != null) {
      return newObject;
    }

    // TODO(Dokotela): think about how much more robust this should be
    if (tn.contains('StructureDefinition/')) {
      final String type = tn.split('StructureDefinition/').last;
      if (type.isNotEmpty) {
        newObject = model.createBuilder(type);
        if (newObject != null) {
          return newObject;
        }
      }
    }
    throw FhirMappingException(message: 'Unable to create object of type $tn');
  }

  Future<FhirNodeBuilder> _buildCoding(String uri, String code) async {
    String? system;
    String? display;
    String? version;
    if (uri.isEmpty) {
      // no system
      system = null;
    } else {
      final vs = await resolver.fetchResourceOfType(uri, 'ValueSet');
      if (vs != null) {
        final ValueSetExpansionOutcome vse = resolver.expandVS(vs);
        if (vse.error != null) {
          throw FhirMappingException(message: vse.error);
        }
        final expanded =
            vse.valueSet
                ?.getChildByName('expansion')
                ?.getChildrenByName('contains') ??
            const <FhirNode>[];
        bool found = false;
        for (final t in expanded) {
          final tCode = t.getChildByName('code')?.primitiveValue;
          final tDisplay = t.getChildByName('display')?.primitiveValue ?? '';
          if (tCode != null) {
            if (tCode == code || code.toLowerCase() == tDisplay.toLowerCase()) {
              system = t.getChildByName('system')?.primitiveValue ?? '';
              version = t.getChildByName('version')?.primitiveValue ?? '';
              display = tDisplay;
              found = true;
              break;
            }
          }
        }
        if (!found) {
          throw FhirMappingException(
            message:
                'The code "$code" is not in the value set '
                '"$uri" (also checked displays)',
          );
        }
      } else {
        system ??= uri;
      }
    }
    final ValidationResult? vr = await resolver.validateCode(
      ValidationOptions().withVersionFlexible(true),
      system,
      version,
      code,
      null,
    );
    if (vr?.display != null) {
      display = vr!.display;
    }
    final coding = _typeFactory('Coding');
    if (system != null) {
      coding.setChildByName('system', model.primitive('uri', system));
    }
    coding.setChildByName('code', model.primitive('code', code));
    if (display != null) coding.setChildByName('display', _string(display));
    if (version != null) coding.setChildByName('version', _string(version));
    return coding;
  }

  String _getParamStringNoNull(
    MappingVariables vars,
    ParameterView parameter,
    String message,
  ) {
    final FhirNodeBuilder? b = _getParam(vars, parameter);

    if (b == null) {
      throw FhirMappingException(
        message:
            'Unable to find a value for ${parameter.valueText}. '
            'Context: $message',
      );
    }
    if (!b.isPrimitive) {
      throw FhirMappingException(
        message:
            'Found a value for ${jsonEncode(_nodeJson(parameter.node))}, but it has type '
            '${b.fhirType} and cannot be treated as a string. '
            'Context: $message',
      );
    }
    if (_numberTypes.contains(b.fhirType) ||
        _dateTimeTypes.contains(b.fhirType) ||
        b.fhirType == 'boolean') {
      throw FhirMappingException(
        message:
            'Found a value for ${jsonEncode(_nodeJson(parameter.node))}, but it has type '
            '${b.fhirType} and cannot be treated as a string. '
            'Context: $message',
      );
    }
    return b.primitiveValue!;
  }

  String? _getParamString(MappingVariables vars, ParameterView parameter) {
    final FhirNodeBuilder? b = _getParam(vars, parameter);

    if (b == null || !b.isPrimitive || !_stringBased(b.fhirType)) {
      return null;
    }
    return b.primitiveValue!;
  }

  /// The value a parameter stands for: a variable's value for a `valueId`,
  /// else the literal, as a builder.
  FhirNodeBuilder? _getParam(MappingVariables vars, ParameterView parameter) {
    final value = parameter.value;
    if (value == null) return null;
    if (!parameter.isVariable) {
      return model.toBuilder(value);
    }
    final String n = value.primitiveValue ?? '';

    FhirNodeBuilder? b = vars.get(MappingVariableMode.INPUT, n);
    b ??= vars.get(MappingVariableMode.OUTPUT, n);
    if (b == null) {
      throw MappingDefinitionException(
        message: 'MappingVariable $n not found (${vars.summary()})',
      );
    }
    return b;
  }

  Future<FhirNodeBuilder?> _translate(
    TransformContext context,
    MapView? map,
    MappingVariables variables,
    List<ParameterView> parameters,
  ) async {
    final sourceElement = _getParam(variables, parameters.first);
    final conceptMapUrl = _getParamStringGeneral(
      variables,
      parameters[1],
      map,
      throwIfNull: false,
    );
    final fieldToReturn =
        parameters.length > 2
            ? _getParamStringGeneral(
              variables,
              parameters[2],
              map,
              throwIfNull: false,
            )
            : 'code';

    try {
      return await _processConceptMapTranslation(
        sourceElement,
        conceptMapUrl,
        fieldToReturn,
        map,
      );
    } catch (e) {
      throw Exception('Error during translation for value $sourceElement: $e');
    }
  }

  Future<FhirNodeBuilder?> _processConceptMapTranslation(
    FhirNodeBuilder? sourceElement,
    String? conceptMapUrl,
    String? fieldToReturn,
    MapView? map,
  ) async {
    final sourceCoding =
        sourceElement == null
            ? null
            : sourceElement.isPrimitive
            ? sourceElement.primitiveValue
            : sourceElement.toJson()['coding'];

    final conceptMap = await _findConceptMap(conceptMapUrl, map);

    return conceptMap == null
        ? null
        : await _translateCoding(conceptMap, sourceCoding, fieldToReturn);
  }

  Future<FhirNodeBuilder?> _translateCoding(
    ConceptMapView conceptMap,
    dynamic sourceCoding,
    String? fieldToReturn,
  ) async {
    FhirNodeBuilder? outcome;

    for (final group in conceptMap.groups) {
      if (sourceCoding is String) {
        outcome = _findMatchInGroup(group, sourceCoding);
      } else if (sourceCoding is Map<String, dynamic>) {
        outcome = _findMatchInGroup(
          group,
          sourceCoding['code'] as String?,
          sourceCoding['system'] as String? ?? '',
        );
      } else if (sourceCoding is List) {
        // A CodeableConcept's codings: the first that the group translates.
        for (final c in sourceCoding.whereType<Map<String, dynamic>>()) {
          outcome = _findMatchInGroup(
            group,
            c['code'] as String?,
            c['system'] as String? ?? '',
          );
          if (outcome != null) break;
        }
      }
      if (outcome != null) break; // Stop if a match is found
    }

    if (outcome == null) {
      final errorSource =
          sourceCoding is String
              ? sourceCoding
              : sourceCoding is Map<String, dynamic>
              ? sourceCoding['code']
              : sourceCoding is List
              ? sourceCoding
                  .whereType<Map<String, dynamic>>()
                  .map((c) => c['code'])
                  .join(', ')
              : sourceCoding;
      throw Exception('No translation found for $errorSource');
    }

    return fieldToReturn == 'code' ? outcome.getChildByName('code') : outcome;
  }

  // Helper method to find a matching Coding in a ConceptMap group
  FhirNodeBuilder? _findMatchInGroup(
    ConceptMapGroupView group,
    String? code, [
    String? system,
  ]) {
    for (final element in group.elements) {
      if ((system == null && element.code == code) ||
          (system == group.source && element.code == code)) {
        final matchingTarget = element.targets.firstWhereOrNull(
          (target) => _isValidEquivalence(target.relationship),
        );

        if (matchingTarget != null) {
          final coding = _typeFactory('Coding');
          if (group.target != null) {
            coding.setChildByName(
              'system',
              model.primitive('uri', group.target!),
            );
          }
          if (matchingTarget.code != null) {
            coding.setChildByName(
              'code',
              model.primitive('code', matchingTarget.code!),
            );
          }
          return coding;
        }
      }
    }
    return null;
  }

  bool _isValidEquivalence(String? equivalence) {
    return equivalence == null ||
        model.matchingRelationships.contains(equivalence.toLowerCase());
  }

  Future<ConceptMapView?> _findConceptMap(
    String? conceptMapUrl,
    MapView? map,
  ) async {
    if (conceptMapUrl == null) return null;

    if (conceptMapUrl.startsWith('#')) {
      final contained = map?.contained.firstWhereOrNull(
        (resource) =>
            resource.fhirType == 'ConceptMap' &&
            resource.getChildByName('id')?.primitiveValue ==
                conceptMapUrl.substring(1),
      );
      return contained == null ? null : ConceptMapView(contained);
    }

    final fetched = await resolver.fetchResourceOfType(
      conceptMapUrl,
      'ConceptMap',
    );
    return fetched == null ? null : ConceptMapView(fetched);
  }

  String? _getParamStringGeneral(
    MappingVariables variables,
    ParameterView parameter,
    MapView? map, {
    required bool throwIfNull,
    String? contextMessage,
  }) {
    final paramValue = _getParam(variables, parameter);

    if (paramValue != null &&
        paramValue.isPrimitive &&
        paramValue.primitiveValue != null) {
      return paramValue.primitiveValue;
    }

    if (throwIfNull) {
      throw FhirMappingException(
        message:
            'Expected a non-null, string-compatible value for parameter '
            '"${parameter.valueText}" in context: $contextMessage, but found '
            '${paramValue?.fhirType}',
      );
    }
    return null;
  }

  String _convertEscaping(String source, String fmt1, String fmt2) {
    // Implement the logic to convert from fmt1 to fmt2
    // For simplicity, here's a basic example handling 'xml' and 'json' escapes
    String unescaped;
    switch (fmt1.toLowerCase()) {
      case 'xml':
        unescaped = htmlEscape.convert(source);
      case 'json':
        unescaped = jsonDecode('"$source"') as String;
      default:
        unescaped = source;
    }

    String escaped;
    switch (fmt2.toLowerCase()) {
      case 'xml':
        escaped = htmlEscape.convert(unescaped);
      case 'json':
        escaped = jsonEncode(unescaped).replaceAll('"', '');
      default:
        escaped = unescaped;
    }

    return escaped;
  }

  FhirNodeBuilder _castToInt(String value, String ruleId, String targetType) {
    try {
      final intValue = int.parse(value);
      return model.primitive('integer', intValue);
    } on FormatException catch (_) {
      throw FHIRMappingCastException(
        message:
            "Rule '$ruleId': Failed to cast '$value' to type "
            "'$targetType'. Invalid number format.",
      );
    }
  }
}
