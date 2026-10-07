// ignore_for_file: lines_longer_than_80_chars, constant_identifier_names

import 'package:collection/collection.dart';
import 'package:fhir_mapping/src/exceptions.dart';
import 'package:fhir_mapping/src/map_views.dart';
import 'package:fhir_mapping/src/mapping_model.dart';
import 'package:fhir_node/fhir_node.dart';
import 'package:fhir_path/fhir_path.dart';

/// Parses FHIR Mapping Language text into a StructureMap of [R]'s version,
/// and renders a StructureMap back to text.
///
/// The parser reads both header forms: the older `map "url" = "name"` and
/// the R5 `/// url = "..."` metadata lines. It builds the StructureMap as
/// JSON and hands it to the [MappingModel], which parses it as the
/// version's resource; the few places where versions spell the map
/// differently (`target.contextType`, `dependent.variable` or
/// `dependent.parameter`, `defaultValue[x]`, ConceptMap `equivalence` or
/// `relationship`) are the model's to say.
class StructureMapParser<R extends FhirNode> {
  /// Constructor for StructureMapParser
  StructureMapParser._(this.model, this.fpe);

  /// Factory method to create an instance of StructureMapParser over
  /// [model]'s version.
  static Future<StructureMapParser<R>> create<R extends FhirNode>(
    MappingModel<R> model,
  ) async {
    final fpe = await FHIRPathEngine.create(
      FhirWorkerContext(binding: model.pathBinding),
    );
    return StructureMapParser<R>._(model, fpe);
  }

  /// The version the parsed map belongs to.
  final MappingModel<R> model;

  /// Token for the 'map' keyword - 'map.where.check'
  static const String MAP_WHERE_CHECK = 'map.where.check';

  /// Token for the 'map' keyword - 'map.where.log'
  static const String MAP_WHERE_LOG = 'map.where.log';

  /// Token for the 'map' keyword - 'map.where.expression'
  static const String MAP_WHERE_EXPRESSION = 'map.where.expression';

  /// Token for the 'map' keyword - 'map.search.expression'
  static const String MAP_SEARCH_EXPRESSION = 'map.search.expression';

  /// Token for the 'map' keyword - 'map.transform.expression'
  static const String MAP_EXPRESSION = 'map.transform.expression';

  /// Defines if multiple targets should be rendered on one line
  static const bool RENDER_MULTIPLE_TARGETS_ONELINE = true;

  /// Variable name given to the one source and target of a simple rule
  static const String AUTO_VAR_NAME = 'vvv';

  /// Default group name for anonymous mappings
  static const String DEF_GROUP_NAME = 'DefaultMappingGroupAnonymousAlias';

  /// Flag to determine if exceptions should be thrown for checks
  bool exceptionsForChecks = true;

  /// Debug flag to enable or disable debug output
  bool debug = false;

  /// FhirPathEngine instance for evaluating expressions
  FHIRPathEngine? fpe;

  /// Renders a StructureMap to map text, in the R5 metadata form
  /// (`/// url = "..."`), which this parser reads back.
  static String render(FhirNode structureMap) {
    final map = MapView(structureMap);
    final b =
        StringBuffer()
          ..write('/// url = "')
          ..write(map.url)
          ..write('"\r\n')
          ..write('/// name = "')
          ..write(map.name)
          ..write('"\r\n')
          ..write('/// title = "')
          ..write(map.title)
          ..write('"\r\n')
          ..write('/// status = "')
          ..write(map.status)
          ..write('"\r\n\r\n');
    if (map.description != null && map.description!.isNotEmpty) {
      _renderMultilineDoco(b, map.description!, 0);
      b.write('\r\n');
    }
    _renderConceptMaps(b, map);
    _renderUses(b, map);
    _renderImports(b, map);
    for (final g in map.groups) {
      _renderGroup(b, g);
    }
    return b.toString();
  }

  /// Main entry point for parsing a StructureMap from map text.
  R parse(String text, String srcName) {
    final lexer = FHIRLexer(source: text, name: srcName, metadataFormat: true);

    try {
      if (lexer.done()) throw lexer.error('Map Input cannot be empty');

      final result = <String, dynamic>{'resourceType': 'StructureMap'};

      // Handle both old and new format. The `map` line and the `///`
      // metadata lines come in either order: the published tutorial maps
      // write `map` first, the SDOHCC maps (sdoh-clinicalcare) write the
      // metadata first (measured 2026-10-07: both SDOHCC maps failed at
      // their `map` line, which came after the metadata).
      while (lexer.hasToken('map') || lexer.hasToken('///')) {
        // Handle both old and new format
        if (lexer.hasToken('map')) {
          // Old format: map "url" = "name"
          lexer.token('map');
          result['url'] = lexer.readConstant('url');
          lexer.token('=');
          result['name'] = lexer.readConstant('name');
          // The header's comment block is the description (the reference
          // parser: `result.setDescription(lexer.getAllComments())`, R4B and
          // R5 StructureMapUtilities.parse).
          // Joined the way the reference lexer's getAllComments joins them:
          // CommaSeparatedStringBuilder("\r\n").addAll → appendIfNotNull,
          // which drops an empty comment line (a bare `//`).
          final comments = lexer.comments
              .where((c) => c.isNotEmpty)
              .join('\r\n');
          lexer.comments.clear();
          if (comments.isNotEmpty) result['description'] = comments;
          result['status'] = 'draft';
        }

        // New format metadata: /// url = "value"
        // Must be processed BEFORE consuming comments
        if (lexer.hasToken('///')) {
          lexer.next();
          final fid = lexer.takeDottedToken();
          lexer.token('=');
          switch (fid) {
            case 'url':
              result['url'] = lexer.readConstant('url');
            case 'name':
              result['name'] = lexer.readConstant('name');
            case 'title':
              result['title'] = lexer.readConstant('title');
            case 'description':
              result['description'] = lexer.readConstant('description');
            case 'status':
              // The reference reads a quoted constant only. Published maps
              // write `/// status = draft` bare (sdoh-clinicalcare's
              // SDOHCC-StructureMapHungerVitalSign, test step14), and their
              // published JSON carries that status, so a bare token is
              // accepted too.
              result['status'] =
                  lexer.isStringConstant()
                      ? lexer.readConstant('status')
                      : lexer.take();
            case 'experimental':
              if (lexer.isStringConstant()) {
                result['experimental'] =
                    lexer.readConstant('experimental') == 'true';
              } else if (lexer.hasToken('true')) {
                lexer.token('true');
                result['experimental'] = true;
              } else {
                lexer.token('false');
                result['experimental'] = false;
              }
            default:
              lexer.readConstant('nothing'); // consume unknown metadata
          }
        }
      }
      // Set defaults if not already set
      if (result['id'] == null && result['name'] is String) {
        result['id'] = (result['name'] as String).replaceAll(' ', '');
      }
      result['status'] ??= 'draft';
      if (result['description'] == null && result['title'] != null) {
        result['description'] = result['title'];
      }

      final contained = <Map<String, dynamic>>[];
      final structures = <Map<String, dynamic>>[];
      final imports = <String>[];
      final groups = <Map<String, dynamic>>[];

      // Parse concept maps
      while (lexer.hasToken('conceptmap')) {
        contained.add(_parseConceptMap(lexer));
      }

      // Parse uses statements
      while (lexer.hasToken('uses')) {
        structures.add(_parseUses(lexer));
      }

      // Parse imports statements
      while (lexer.hasToken('imports')) {
        imports.add(_parseImports(lexer));
      }

      // Parse groups
      while (!lexer.done()) {
        groups.add(_parseGroup(lexer));
      }
      if (contained.isNotEmpty) result['contained'] = contained;
      if (structures.isNotEmpty) result['structure'] = structures;
      if (imports.isNotEmpty) result['import'] = imports;
      if (groups.isNotEmpty) result['group'] = groups;

      // Add narrative text if provided
      if (text.isNotEmpty) {
        result['text'] = {
          'status': 'additional',
          'div':
              text.startsWith('<div>')
                  ? text
                  : '<div xmlns="http://www.w3.org/1999/xhtml">${text.replaceAll("<", "&lt;").replaceAll(">", "&gt;")}</div>',
        };
      }

      return model.fromJson(result);
    } catch (e) {
      throw FhirParserException(
        message:
            'Position ${lexer.currentLocation.line}, ${lexer.currentLocation.column}',
        cause: e,
        stackTrace: StackTrace.current,
      );
    }
  }

  Map<String, dynamic> _parseRule(FHIRLexer lexer, bool newFmt) {
    // Initialize local variables for parsing
    String? name;
    var documentation = lexer.getFirstComment();
    final sources = <Map<String, dynamic>>[];
    final targets = <Map<String, dynamic>>[];
    final dependents = <Map<String, dynamic>>[];
    final rules = <Map<String, dynamic>>[];

    // Determine rule name and format
    if (!newFmt) {
      name = lexer.takeDottedToken();
      lexer
        ..token(':')
        ..token('for');
    } else {
      documentation = lexer.getFirstComment() ?? documentation;
    }

    // Source parsing loop
    var done = false;
    while (!done) {
      final source = _parseSource(lexer);
      sources.add(source);
      done = !lexer.hasToken(',');
      if (!done) lexer.next();
    }

    // Target parsing
    if ((newFmt && lexer.hasToken('->')) ||
        (!newFmt && lexer.hasToken('make'))) {
      lexer.token(newFmt ? '->' : 'make');
      done = false;
      while (!done) {
        final target = _parseTarget(lexer);
        targets.add(target);
        done = !lexer.hasToken(',');
        if (!done) lexer.next();
      }
    }

    // Handling nested rules or dependencies if present
    if (lexer.hasToken('then')) {
      lexer.token('then');
      if (lexer.hasToken('{')) {
        lexer.token('{');
        while (!lexer.hasToken('}')) {
          if (lexer.done()) {
            throw lexer.error(
              "Premature termination expecting '}' in nested group",
            );
          }
          final innerRule = _parseRule(lexer, newFmt);
          rules.add(innerRule);
        }
        lexer.token('}');
      } else {
        // Handle function calls within then clause
        done = false;
        while (!done) {
          final dependent = _parseRuleReference(lexer);
          dependents.add(dependent);
          done = !lexer.hasToken(',');
          if (!done) lexer.next();
        }
      }
    } else if (documentation == null && lexer.hasComments()) {
      documentation = lexer.getFirstComment();
    }

    // Simple syntax adjustment if applicable
    if (_isSimpleSyntax(sources, targets, dependents, rules)) {
      sources.first['variable'] = AUTO_VAR_NAME;
      targets.first['variable'] = AUTO_VAR_NAME;
      targets.first['transform'] = 'create';
    }

    // Final naming and semicolon handling
    if (newFmt) {
      if (lexer.isConstant()) {
        if (lexer.isStringConstant()) {
          name = model.ruleName(lexer.readConstant('ruleName'));
        } else {
          name = lexer.take();
        }
      } else {
        if (sources.isNotEmpty && sources.first['element'] is String) {
          name = sources.first['element'] as String;
          if (sources.first['type'] case final String type
              when type.isNotEmpty) {
            // Only concatenate if type is not null and valid
            name = '$name${type[0].toUpperCase()}${type.substring(1)}';
          }
        } else if (exceptionsForChecks) {
          throw lexer.error('Complex rules must have an explicit name');
        }
      }
      if (lexer.hasToken(';')) lexer.token(';');
    }

    // Append any post-rule comments to documentation. This is what the
    // published tutorial examples show (step6b: a comment after the rule's
    // `;` is its documentation; step12: the next rule's leading comment is
    // appended with '\n'), measured 2026-10-06 over the 58 published
    // examples; the current reference parser takes nothing here, and maps
    // compiled by it (the ahdis CDA corpus) differ in documentation only.
    if (lexer.hasComments()) {
      final postComment = lexer.getFirstComment();
      documentation =
          (documentation != null && documentation.isNotEmpty)
              ? '$documentation\n$postComment'
              : postComment;
    }

    // Return the completed rule with documentation
    return {
      'name': name ?? AUTO_VAR_NAME,
      if (documentation?.isNotEmpty ?? false) 'documentation': documentation,
      'source': sources,
      if (targets.isNotEmpty) 'target': targets,
      if (dependents.isNotEmpty) 'dependent': dependents,
      if (rules.isNotEmpty) 'rule': rules,
    };
  }

  /// Maps for tracking aliases and variables
  final Map<String, String> aliasToUrlMap = {};

  /// New map for variables in groups
  final Map<String, String> variableToAliasMap = {};

  Map<String, dynamic> _parseUses(FHIRLexer lexer) {
    lexer.token('uses');

    // Collect URL and alias information
    final url = lexer.readConstant('url');
    String? alias;
    if (lexer.hasToken('alias')) {
      lexer.token('alias');
      alias = lexer.take();
    }
    lexer.token('as');
    final mode = lexer.take();
    lexer.skipToken(';');
    final documentation = lexer.getFirstComment();

    // Store alias for identifier tracking in later parts
    if (alias != null) {
      aliasToUrlMap[alias] = url; // alias-to-URL mapping
    }

    return {
      'url': url,
      if (alias != null) 'alias': alias,
      'mode': mode,
      if (documentation != null) 'documentation': documentation,
    };
  }

  String _parseImports(FHIRLexer lexer) {
    lexer.token('imports');

    // Collect the import URL
    final importUrl = lexer.readConstant('url');
    lexer
      ..skipToken(';')
      ..getFirstComment(); // Consume any comments

    return importUrl;
  }

  Map<String, dynamic> _parseGroup(FHIRLexer lexer) {
    // Capture initial comments and token
    final comment = lexer.getAllComments();

    lexer.token('group'); // Should consume 'group' token

    // Initialize variables
    final documentation = comment.isNotEmpty ? comment : null;
    var newFmt = false;
    String? typeMode;
    String? extends_;
    final inputs = <Map<String, dynamic>>[];
    final rules = <Map<String, dynamic>>[];

    // Check for 'for' token to determine type mode
    if (lexer.hasToken('for')) {
      lexer.token('for');
      if (lexer.current == 'type') {
        lexer
          ..token('type')
          ..token('+')
          ..token('types');
        typeMode = 'type-and-types';
      } else {
        lexer.token('types');
        typeMode = 'types';
      }
    }
    // Don't set typeMode to anything if there's no 'for' token

    // Capture and print group name
    final name = lexer.take();

    // Handle new format inputs
    if (lexer.hasToken('(')) {
      newFmt = true;
      lexer.take(); // Consume '('

      while (!lexer.hasToken(')')) {
        final input = _parseInput(lexer, true);
        inputs.add(input);

        if (lexer.hasToken(',')) {
          lexer.token(',');
        }
      }
      lexer.take(); // Consume ')'
    }

    // Check for group extension
    if (lexer.hasToken('extends')) {
      lexer.next();
      extends_ = lexer.take();
    }

    // Check if new format with type mode
    if (newFmt) {
      if (lexer.hasToken('<')) {
        lexer
          ..token('<')
          ..token('<');
        if (lexer.hasToken('types')) {
          typeMode = 'types';
          lexer.token('types');
        } else {
          lexer
            ..token('type')
            ..token('+');
          typeMode = 'type-and-types';
        }
        lexer
          ..token('>')
          ..token('>');
      }
      lexer.token('{');
    }

    // Parsing rules in newFmt group
    if (newFmt) {
      while (!lexer.hasToken('}')) {
        if (lexer.done()) {
          throw lexer.error("Premature termination expecting '}'");
        }

        final rule = _parseRule(lexer, true);
        rules.add(rule);
      }
      lexer.token('}'); // Close current group block
    } else {
      while (lexer.hasToken('input')) {
        final input = _parseInput(lexer, false);
        inputs.add(input);
      }
      while (!lexer.hasToken('endgroup')) {
        if (lexer.done()) {
          throw lexer.error("Premature termination expecting 'endgroup'");
        }

        final rule = _parseRule(lexer, false);
        rules.add(rule);
      }
      lexer.token('endgroup');
    }

    // Ensure proper lexer state after group parsing
    if (lexer.hasToken('group')) {
      // Do nothing, the next iteration will handle it
    } else {
      lexer.next(); // Move to the next token if no group follows
    }

    typeMode ??= model.groupTypeModeDefault;
    return {
      'name': name,
      if (extends_ != null) 'extends': extends_,
      if (typeMode != null) 'typeMode': typeMode,
      if (documentation != null) 'documentation': documentation,
      'input': inputs,
      // Always written: StructureMap.group.rule is 1..* in R4B, so the
      // model's fromJson reads the list unconditionally, and a group with
      // no rules (`group Any(source src, target tgt) {}`, the ahdis
      // datatypes maps, 2026-10-06) failed to build on the missing key.
      'rule': rules,
    };
  }

  Map<String, dynamic> _parseInput(FHIRLexer lexer, bool newFmt) {
    String? mode;
    String? name;
    String? type;
    String? documentation;

    if (newFmt) {
      mode = lexer.take();
    } else {
      lexer.token('input');
    }
    name = lexer.take();
    if (lexer.hasToken(':')) {
      lexer.token(':');
      type = lexer.take();
    }
    if (!newFmt) {
      lexer.token('as');
      mode = lexer.take();
      documentation = lexer.getAllComments();
      lexer.skipToken(';');
    }

    // Store variable name and type in variable-to-alias map for later reference
    if (type != null) {
      variableToAliasMap[name] = type;
    }

    return {
      if (mode != null) 'mode': mode,
      'name': name,
      if (type != null) 'type': type,
      if (documentation != null && documentation.isNotEmpty)
        'documentation': documentation,
    };
  }

  Map<String, dynamic> _parseSource(FHIRLexer lexer) {
    final source = <String, dynamic>{'context': lexer.take()};

    // Handle 'search' context special case
    if (source['context'] == 'search' && lexer.hasToken('(')) {
      source['context'] = '@search';
      lexer.take();
      final expressionNode = fpe?.parseLexer(lexer);
      if (expressionNode != null) {
        source['element'] = expressionNode.toString();
      }
      lexer.token(')');
    } else if (lexer.hasToken('.')) {
      lexer.token('.');
      final s = lexer.take();
      source['element'] =
          s.startsWith('"') || s.startsWith('`') ? lexer.processConstant(s) : s;
    }

    // Additional step to ensure tokens are properly split and checked
    if (lexer.hasToken(':')) {
      lexer.token(':');
      source['type'] = lexer.takeDottedToken();
      if (!lexer.hasTokenList([
        'as',
        'first',
        'last',
        'not_first',
        'not_last',
        'only_one',
        'default',
      ])) {
        source['min'] = int.parse(lexer.take());
        lexer.token('..');
        source['max'] = lexer.take();
      }
    }

    if (lexer.hasToken('default')) {
      lexer.token('default');
      source[model.sourceDefaultValueKey] = lexer.readConstant('default value');
    }

    if ([
      'first',
      'last',
      'not_first',
      'not_last',
      'only_one',
    ].contains(lexer.current)) {
      source['listMode'] = lexer.take();
    }

    if (lexer.hasToken('as')) {
      lexer.take();
      source['variable'] = lexer.take();
    }

    // Capture condition and check expressions
    if (lexer.hasToken('where')) {
      lexer.take();
      source['condition'] = fpe?.parseLexer(lexer).toString();
    }
    if (lexer.hasToken('check')) {
      lexer.take();
      source['check'] = fpe?.parseLexer(lexer).toString();
    }
    if (lexer.hasToken('log')) {
      lexer.take();
      source['logMessage'] = fpe?.parseLexer(lexer).toString();
    }

    return source;
  }

  Map<String, dynamic> _parseTarget(FHIRLexer lexer) {
    final target = <String, dynamic>{};
    void contextOf(String variable) {
      target['context'] = variable;
      if (model.targetHasContextType) target['contextType'] = 'variable';
    }

    // 1) Grab the first token (e.g., "someContext" or "variableName")
    String? start = lexer.take();

    // 2) If there's a '.' after 'start', that means "start.element"
    if (lexer.hasToken('.')) {
      contextOf(start);
      start = null;
      lexer.token('.');
      target['element'] = lexer.take();
    }

    // 3) Figure out if we have '='. If so, read the next token as "name"
    String? name;
    var isConstant = false;
    if (lexer.hasToken('=')) {
      if (start != null) {
        contextOf(start);
      }
      lexer.token('=');
      isConstant = lexer.isConstant();
      name = lexer.take();
    } else {
      name = start;
    }

    final parameters = <Map<String, dynamic>>[];
    target['parameter'] = parameters;

    // 4) Now handle three major cases:
    //
    //    (a) name == '(' -> "inline fluentpath expression"
    //    (b) we see '(' next -> transform(...) call
    //    (c) otherwise it's just name != null -> transform = copy

    // 4a) Inline fluentpath: name == "("
    if (name == '(') {
      target['transform'] = 'evaluate';
      final node = fpe?.parseLexer(lexer); // parse the expression

      // Add that expression as a parameter
      if (node != null) {
        parameters.add({'valueString': node.toString()});
      }
      lexer.token(')'); // consume the closing parenthesis

      // 4b) If there's a '(' token after 'name',
      //     then it's transform(name)(...) syntax
    } else if (lexer.hasToken('(')) {
      target['transform'] = name;
      lexer.token('(');
      if (name == 'evaluate') {
        // The first argument is a parameter, then we expect a comma,
        // then an expression
        final params = _parseParameter(lexer);
        lexer.token(',');
        final node = fpe?.parseLexer(lexer);

        parameters.addAll(params);
        if (node != null) {
          parameters.add({'valueString': node.toString()});
        }
      } else {
        // Keep collecting parameters until we see ')'
        while (!lexer.hasToken(')')) {
          final params = _parseParameter(lexer);
          parameters.addAll(params);
          if (!lexer.hasToken(')')) {
            lexer.token(',');
          }
        }
      }
      lexer.token(')'); // close the transform call

      // 4c) Otherwise, if name != null, it's a plain "copy" transform
    } else if (name != null) {
      target['transform'] = 'copy';
      if (model.targetHasContextType) target['contextType'] ??= 'variable';
      if (!isConstant) {
        // Possibly "someName.more.dots"
        final buffer = StringBuffer(name);
        while (lexer.hasToken('.')) {
          buffer
            ..write(lexer.take())
            ..write(lexer.take());
        }
        parameters.add({'valueId': buffer.toString()});
      } else {
        // If it's a numeric constant
        final intVal = int.tryParse(name);
        if (intVal != null) {
          parameters.add({'valueInteger': intVal});
        } else {
          final boolVal = bool.tryParse(name);
          if (boolVal != null) {
            parameters.add({'valueBoolean': boolVal});
          } else {
            // Otherwise treat it as a FHIR constant/string
            parameters.add({'valueString': lexer.processConstant(name)});
          }
        }
      }
    }

    // 5) If there's an "as someVar" syntax
    if (lexer.hasToken('as')) {
      lexer.take(); // consume the "as"
      target['variable'] = lexer.take();
      if (model.targetHasContextType) target['contextType'] = 'variable';
    }

    // 6) Check for "first", "last", "share", "collate"
    while (['first', 'last', 'share', 'collate'].contains(lexer.current)) {
      final listMode = (target['listMode'] ??= <String>[]) as List<String>;
      if (lexer.current == 'share') {
        listMode.add('share');
        lexer.next(); // consume 'share'
        target['listRuleId'] = lexer.take(); // the next token is the rule ID
      } else {
        listMode.add(lexer.current == 'first' ? 'first' : 'last');
        lexer.next(); // consume 'first' or 'last'
      }
    }

    if (parameters.isEmpty) target.remove('parameter');
    // Return the completed target
    return target;
  }

  Map<String, dynamic> _parseRuleReference(FHIRLexer lexer) {
    // Collect values in local variables
    final name = lexer.take();
    final parameters = <Map<String, dynamic>>[];
    lexer.token('(');
    var done = false;
    while (!done) {
      // Parse each parameter instead of just taking strings
      parameters.addAll(_parseParameter(lexer));
      done = !lexer.hasToken(',');
      if (!done) {
        lexer.next();
      }
    }
    lexer.token(')');

    // The version says whether these are `variable` strings or `parameter`s
    return {'name': name, ...model.dependentArguments(parameters)};
  }

  List<Map<String, dynamic>> _parseParameter(FHIRLexer lexer) {
    if (!lexer.isConstant()) {
      return [
        {'valueId': lexer.take()},
      ];
    } else if (lexer.isStringConstant()) {
      return [
        {'valueString': lexer.readConstant('??')},
      ];
    } else {
      return [_readConstant(lexer.take(), lexer)];
    }
  }

  Map<String, dynamic> _readConstant(String s, FHIRLexer lexer) {
    if (s == 'true') {
      return {'valueBoolean': true};
    } else if (s == 'false') {
      return {'valueBoolean': false};
    } else if (int.tryParse(s) != null) {
      return {'valueInteger': int.parse(s)};
    } else if (double.tryParse(s) != null) {
      return {'valueDecimal': double.parse(s)};
    } else {
      return {'valueString': lexer.processConstant(s)};
    }
  }

  bool _isSimpleSyntax(
    List<Map<String, dynamic>> sources,
    List<Map<String, dynamic>> targets,
    List<Map<String, dynamic>> dependents,
    List<Map<String, dynamic>> rules,
  ) {
    return sources.length == 1 &&
        targets.length == 1 &&
        sources.first['element'] != null &&
        sources.first['variable'] == null &&
        targets.first['context'] != null &&
        targets.first['element'] != null &&
        targets.first['variable'] == null &&
        ((targets.first['parameter'] as List<dynamic>?)?.isEmpty ?? true) &&
        dependents.isEmpty &&
        rules.isEmpty;
  }

  Map<String, dynamic> _parseConceptMap(FHIRLexer lexer) {
    lexer.token('conceptmap');

    // Collect values in local variables
    final id = lexer.readConstant('map id');
    final cmId = id.startsWith('#') ? id.substring(1) : id;

    final prefixes = <String, String>{};
    final groups = <Map<String, dynamic>>[];

    lexer.token('{');

    // Parse prefixes
    while (lexer.hasToken('prefix')) {
      lexer.token('prefix');
      final n = lexer.take();
      lexer.token('=');
      final v = lexer.readConstant('prefix url');
      prefixes[n] = v;
    }

    final unmappedModes = <String, String>{};

    // Parse unmapped modes
    while (lexer.hasToken('unmapped')) {
      lexer
        ..token('unmapped')
        ..token('for');
      final n = _readPrefix(prefixes, lexer);
      lexer.token('=');
      final v = lexer.take();
      if (v == 'provided') {
        unmappedModes[n] = model.unmappedProvidedMode;
      } else {
        throw lexer.error(
          'Only unmapped mode PROVIDED is supported at this time',
        );
      }
    }

    final relationshipElement = model.conceptMapRelationshipElement;

    // Parse equivalences within the concept map
    while (!lexer.hasToken('}')) {
      final srcs = _readPrefix(prefixes, lexer);
      lexer.token(':');
      final sc =
          lexer.current?.startsWith('"') ?? false
              ? lexer.readConstant('code')
              : lexer.take();
      final token = lexer.take();
      final eq = model.conceptMapRelationship(token);
      if (eq == null) {
        throw lexer.error("Unknown relationship token '$token'");
      }
      // R4B's `--` (unmatched) names no target; every other token does.
      final unmatched = token == '--';
      final tgts = unmatched ? null : _readPrefix(prefixes, lexer);

      // Find or create the appropriate group
      var group = groups.firstWhereOrNull(
        (g) => g['source'] == srcs && g['target'] == tgts,
      );
      if (group == null) {
        group = {
          'source': srcs,
          if (tgts != null) 'target': tgts,
          'element': <Map<String, dynamic>>[],
          if (unmappedModes.containsKey(srcs))
            'unmapped': {'mode': unmappedModes[srcs]},
        };
        groups.add(group);
      }

      // Collect elements for the group
      final code = sc.startsWith('"') ? lexer.processConstant(sc) : sc;
      final Map<String, dynamic> target;
      if (!unmatched) {
        lexer.token(':');
        var targetCode = lexer.take();
        targetCode =
            targetCode.startsWith('"')
                ? lexer.processConstant(targetCode)
                : targetCode;
        final comment = lexer.getFirstComment();
        target = {
          'code': targetCode,
          relationshipElement: eq,
          if (comment != null) 'comment': comment,
        };
      } else {
        final comment = lexer.getFirstComment();
        target = {
          relationshipElement: eq,
          if (comment != null) 'comment': comment,
        };
      }

      (group['element'] as List<Map<String, dynamic>>).add({
        'code': code,
        'target': [target],
      });
    }

    lexer.token('}');

    // Create and return the ConceptMap
    return {
      'resourceType': 'ConceptMap',
      'id': cmId,
      'status': 'draft',
      'group': groups,
    };
  }

  // Helper methods matching the .NET code
  static String _escapeJson(String s) {
    return s
        .replaceAll('"', r'\"')
        .replaceAll('\n', r'\n')
        .replaceAll('\r', r'\r')
        .replaceAll('\t', r'\t');
  }

  String _readPrefix(Map<String, String> prefixes, FHIRLexer lexer) {
    final prefix = lexer.take();
    if (!prefixes.containsKey(prefix)) {
      throw lexer.error("Unknown prefix '$prefix'");
    }
    return prefixes[prefix]!;
  }

  static void _renderConceptMaps(StringBuffer b, MapView map) {
    for (final r in map.contained) {
      if (r.fhirType == 'ConceptMap') {
        _produceConceptMap(b, ConceptMapView(r));
      }
    }
  }

  static void _produceConceptMap(StringBuffer b, ConceptMapView cm) {
    b
      ..write('conceptmap "')
      ..write(cm.id)
      ..write('" {\r\n');
    final prefixesSrc = <String, String>{};
    final prefixesTgt = <String, String>{};
    var prefix = 's'.codeUnitAt(0);

    for (final cg in cm.groups) {
      if (!prefixesSrc.containsKey(cg.source)) {
        prefixesSrc[cg.source ?? ''] = String.fromCharCode(prefix);
        b
          ..write('  prefix ')
          ..write(String.fromCharCode(prefix))
          ..write(' = "')
          ..write(cg.source)
          ..write('"\r\n');
        prefix++;
      }
      if (!prefixesTgt.containsKey(cg.target)) {
        prefixesTgt[cg.target ?? ''] = String.fromCharCode(prefix);
        b
          ..write('  prefix ')
          ..write(String.fromCharCode(prefix))
          ..write(' = "')
          ..write(cg.target)
          ..write('"\r\n');
        prefix++;
      }
    }
    b.write('\n');
    for (final cg in cm.groups) {
      if (cg.unmappedMode != null) {
        b
          ..write('  unmapped for ')
          ..write(prefixesSrc[cg.source ?? ''])
          ..write(' = ')
          ..write(cg.unmappedMode)
          ..write('\n');
      }
    }

    for (final cg in cm.groups) {
      for (final ce in cg.elements) {
        b
          ..write('  ')
          ..write(prefixesSrc[cg.source ?? ''])
          ..write(':');
        if (_isToken(ce.code ?? '')) {
          b.write(ce.code);
        } else {
          b
            ..write('"')
            ..write(ce.code)
            ..write('"');
        }
        b.write(' ');
        final targets = ce.targets;
        final e = targets.isNotEmpty ? targets.first.relationship : null;
        b
          ..write(e != null ? _getChar(e) : '??')
          ..write(' ')
          ..write(prefixesTgt[cg.target ?? ''])
          ..write(':');
        if (targets.isNotEmpty) {
          final targetCode = targets.first.code;
          if (targetCode != null && _isToken(targetCode)) {
            b.write(targetCode);
          } else {
            b
              ..write('"')
              ..write(targetCode)
              ..write('"');
          }
        }
        b.write('\n');
      }
    }
    b.write('}\r\n\r\n');
  }

  /// The map-language token for a ConceptMap relationship, in either
  /// vocabulary: R4B equivalence codes and R5 relationship codes.
  static String _getChar(String relationship) {
    switch (relationship) {
      case 'relatedto':
      case 'related-to':
        return '-';
      case 'equal':
        return '=';
      case 'equivalent':
        return '==';
      case 'disjoint':
      case 'notrelatedto':
      case 'not-related-to':
        return '!=';
      case 'unmatched':
        return '--';
      case 'wider':
      case 'sourceisnarrowerthantarget':
      case 'source-is-narrower-than-target':
        return '<=';
      case 'subsumes':
        return '<-';
      case 'narrower':
      case 'sourceisbroaderthantarget':
      case 'source-is-broader-than-target':
        return '>=';
      case 'specializes':
        return '>-';
      case 'inexact':
        return '~';
      default:
        return '??';
    }
  }

  static void _renderUses(StringBuffer b, MapView map) {
    for (final s in map.structures) {
      b
        ..write('uses "')
        ..write(s.url)
        ..write('" ');
      if (s.alias != null && s.alias!.isNotEmpty) {
        b
          ..write('alias ')
          ..write(s.alias)
          ..write(' ');
      }
      b
        ..write('as ')
        ..write(s.mode);
      _renderDoco(b, s.documentation);
      b.write('\n');
    }
    if (map.structures.isNotEmpty) b.write('\n');
  }

  static void _renderImports(StringBuffer b, MapView map) {
    if (map.imports.isNotEmpty) {
      for (final s in map.imports) {
        b.write('imports "$s"\n');
      }
      b.write('\n');
    }
  }

  static void _renderGroup(StringBuffer b, GroupView g) {
    if (g.documentation != null && g.documentation!.isNotEmpty) {
      _renderMultilineDoco(b, g.documentation!, 0);
    }
    b
      ..write('group ')
      ..write(g.name)
      ..write('(');
    var first = true;
    for (final gi in g.inputs) {
      if (first) {
        first = false;
      } else {
        b.write(', ');
      }
      b
        ..write(gi.mode)
        ..write(' ')
        ..write(gi.name);
      if (gi.type != null && gi.type!.isNotEmpty) {
        b
          ..write(' : ')
          ..write(gi.type);
      }
    }
    b.write(')');
    if (g.extends_ != null && g.extends_!.isNotEmpty) {
      b
        ..write(' extends ')
        ..write(g.extends_);
    }

    switch (g.typeMode) {
      case 'types':
        b.write(' <<types>>');
      case 'type-and-types':
        b.write(' <<type+>>');
      default:
        break;
    }
    b.write(' {\r\n');
    for (final r in g.rules) {
      _renderRule(b, r, 2);
    }
    b.write('}\r\n\r\n');
  }

  static void _renderRule(StringBuffer b, RuleView r, int indent) {
    if (r.documentation != null && r.documentation!.isNotEmpty) {
      _renderMultilineDoco(b, r.documentation!, indent);
    }
    b.write(' ' * indent);
    final canBeAbbreviated = _checkIsSimple(r);

    var first = true;
    for (final rs in r.sources) {
      if (first) {
        first = false;
      } else {
        b.write(', ');
      }
      _renderSource(b, rs, canBeAbbreviated);
    }
    final targets = r.targets;
    if (targets.isNotEmpty) {
      b.write(' -> ');
      first = true;
      for (final rt in targets) {
        if (first) {
          first = false;
        } else {
          b.write(', ');
        }
        if (RENDER_MULTIPLE_TARGETS_ONELINE) {
          b.write(' ');
        } else {
          b
            ..write('\n')
            ..write(' ' * (indent + 4));
        }
        _renderTarget(b, rt, canBeAbbreviated);
      }
    }
    final rules = r.rules;
    if (rules.isNotEmpty) {
      b.write(' then {\r\n');
      for (final ir in rules) {
        _renderRule(b, ir, indent + 2);
      }
      b
        ..write(' ' * indent)
        ..write('}');
    } else {
      final dependents = r.dependents;
      if (dependents.isNotEmpty) {
        b.write(' then ');
        first = true;
        for (final rd in dependents) {
          if (first) {
            first = false;
          } else {
            b.write(', ');
          }
          b
            ..write(rd.name)
            ..write('(');
          var ifirst = true;
          for (final rdp in rd.arguments) {
            if (ifirst) {
              ifirst = false;
            } else {
              b.write(', ');
            }
            b.write(rdp);
          }
          b.write(')');
        }
      }
    }
    if (r.name?.isNotEmpty ?? false) {
      var n = _ntail(r.name!);
      if (!n.startsWith('"')) n = '"$n"';
      if (!_matchesName(n, r.sources)) {
        b
          ..write(' ')
          ..write(n);
      }
    }
    b
      ..write(';')
      ..write('\n');
  }

  static bool _matchesName(String n, List<SourceView> source) {
    if (source.length != 1) return false;
    final src = source.first;
    var s = src.element;
    if (s == null || s.isEmpty) return false;
    if (n == s || n == '"$s"') return true;
    if (src.type != null && src.type!.isNotEmpty) {
      s = '$s-${src.type}';
      if (n == s || n == '"$s"') return true;
    }
    return false;
  }

  static String _ntail(String oldName) {
    var name = oldName;
    if (name.startsWith('"') && name.endsWith('"')) {
      name = name.substring(1, name.length - 1);
    }
    return '"${name.contains('.') ? name.substring(name.lastIndexOf('.') + 1) : name}"';
  }

  static bool _checkIsSimple(RuleView r) {
    final sources = r.sources;
    final targets = r.targets;
    return (sources.length == 1 &&
            sources.first.element != null &&
            sources.first.variable != null) &&
        (targets.length == 1 &&
            targets.first.variable != null &&
            (targets.first.transform == null ||
                targets.first.transform == 'create') &&
            targets.first.parameters.isEmpty) &&
        r.dependents.isEmpty &&
        r.rules.isEmpty;
  }

  static void _renderSource(StringBuffer b, SourceView rs, bool abbreviate) {
    b.write(rs.context);
    if (rs.context == '@search') {
      b
        ..write('(')
        ..write(rs.element)
        ..write(')');
    } else if (rs.element != null && rs.element!.isNotEmpty) {
      b
        ..write('.')
        ..write(rs.element);
    }
    if (rs.type != null && rs.type!.isNotEmpty) {
      b
        ..write(' : ')
        ..write(rs.type);
      if (rs.min != null) {
        b
          ..write(' ')
          ..write(rs.min)
          ..write('..')
          ..write(rs.max);
      }
    }

    if (rs.listMode != null) {
      b
        ..write(' ')
        ..write(rs.listMode);
    }
    final defaultValue = rs.defaultValue;
    if (defaultValue != null) {
      b
        ..write(' default ')
        ..write('"${_escapeJson(defaultValue.primitiveValue ?? '')}"');
    }
    if (!abbreviate && rs.variable != null && rs.variable!.isNotEmpty) {
      b
        ..write(' as ')
        ..write(rs.variable);
    }
    if (rs.condition != null && rs.condition!.isNotEmpty) {
      b
        ..write(' where ')
        ..write(rs.condition);
    }
    if (rs.check != null && rs.check!.isNotEmpty) {
      b
        ..write(' check ')
        ..write(rs.check);
    }
    if (rs.logMessage != null && rs.logMessage!.isNotEmpty) {
      b
        ..write(' log ')
        ..write(rs.logMessage);
    }
  }

  static void _renderTarget(StringBuffer b, TargetView rt, bool abbreviate) {
    if (rt.context != null && rt.context!.isNotEmpty) {
      b.write(rt.context);
      if (rt.element != null && rt.element!.isNotEmpty) {
        b
          ..write('.')
          ..write(rt.element);
      }
    }
    final parameters = rt.parameters;
    if (!abbreviate && rt.transform != null) {
      if (rt.context != null && rt.context!.isNotEmpty) {
        b.write(' = ');
      }
      if (rt.transform == 'copy' && parameters.length == 1) {
        _renderTransformParam(b, parameters.first);
      } else if (rt.transform == 'evaluate' && parameters.length == 1) {
        b
          ..write('(')
          ..write(parameters.first.valueText)
          ..write(')');
      } else if (rt.transform == 'evaluate' && parameters.length == 2) {
        b
          ..write(rt.transform)
          ..write('(')
          ..write(parameters.first.valueText)
          ..write(', ')
          ..write(parameters[1].valueText)
          ..write(')');
      } else {
        b
          ..write(rt.transform)
          ..write('(');
        var first = true;
        for (final rtp in parameters) {
          if (first) {
            first = false;
          } else {
            b.write(', ');
          }
          _renderTransformParam(b, rtp);
        }
        b.write(')');
      }
    }
    if (!abbreviate && rt.variable != null && rt.variable!.isNotEmpty) {
      b
        ..write(' as ')
        ..write(rt.variable);
    }
    for (final lm in rt.listModes) {
      b
        ..write(' ')
        ..write(lm);
      if (lm == 'share') {
        b
          ..write(' ')
          ..write(rt.listRuleId);
      }
    }
  }

  static void _renderTransformParam(StringBuffer b, ParameterView rtp) {
    final value = rtp.valueText ?? '';
    if (const {'boolean', 'integer', 'decimal'}.contains(rtp.valueType)) {
      b.write(value);
    } else {
      b.write("'${_escapeJava(value)}'");
    }
  }

  static void _renderDoco(StringBuffer b, String? doco) {
    if (doco == null || doco.isEmpty) return;
    if (b.isNotEmpty &&
        !b.toString().endsWith('\n') &&
        !b.toString().endsWith(' ')) {
      b.write(' ');
    }
    b
      ..write('// ')
      ..write(
        doco
            .replaceAll('\r\n', ' ')
            .replaceAll('\r', ' ')
            .replaceAll('\n', ' '),
      );
  }

  static void _renderMultilineDoco(StringBuffer b, String doco, int indent) {
    if (doco.isEmpty) return;
    final lines = doco.replaceAll('\r\n', '\n').split(RegExp(r'[\r\n]'));
    for (final line in lines) {
      b.write(' ' * indent);
      _renderDoco(b, line);
      b.write('\r\n');
    }
  }

  static String _escapeJava(String s) {
    return s
        .replaceAll(r'\', r'\\')
        .replaceAll('"', r'\"')
        .replaceAll("'", r"\'")
        .replaceAll('\b', r'\b')
        .replaceAll('\f', r'\f')
        .replaceAll('\n', r'\n')
        .replaceAll('\r', r'\r')
        .replaceAll('\t', r'\t');
  }

  // Helper method to check if a string is a valid token
  static bool _isToken(String s) {
    return RegExp(r'^[a-zA-Z_][a-zA-Z0-9_]*$').hasMatch(s);
  }
}
