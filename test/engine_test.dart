import 'package:fhir_mapping/fhir_mapping.dart';
import 'package:fhir_node/fhir_node.dart';
import 'package:test/test.dart';

import 'support/json_builder.dart';

/// The engine over the stub model: every transform, group resolution by
/// name and by type, dependents, `extends`, and the ConceptMap translate
/// paths, with no FHIR version package loaded.
Future<void> main() async {
  const model = StubMappingModel();
  final parser = await StructureMapParser.create(model);
  final cache = CanonicalResourceCache();

  Future<Map<String, dynamic>> run(
    String mapText,
    Map<String, dynamic> source, [
    String targetType = 'Patient',
  ]) async {
    final map = parser.parse(mapText, 'test');
    final engine = await FhirMapEngine.create(cache, model);
    final out = await engine.transformBuilder(
      '',
      JsonNodeBuilder.resource(source),
      map,
      JsonNodeBuilder.resource({'resourceType': targetType}),
    );
    return model.toJson(out as JsonNode);
  }

  const mapLine = 'map "http://example.org/StructureMap/t" = "t"';
  const uses = '''
uses "http://hl7.org/fhir/StructureDefinition/Patient" as source
uses "http://hl7.org/fhir/StructureDefinition/Patient" as target
''';
  const header = '$mapLine\n$uses';

  test('copy of a primitive and create of a complex child', () async {
    final out = await run(
      '''
$header
group main(source src : Patient, target tgt : Patient) {
  src.gender as g -> tgt.gender = g "r1";
  src.name as n -> tgt.name = create('HumanName') as t then {
    n.family as f -> t.family = f "r2";
    n.given as g -> t.given = g "r3";
  } "r4";
}
''',
      {
        'resourceType': 'Patient',
        'gender': 'female',
        'name': [
          {
            'family': 'Okello',
            'given': ['Grace', 'A'],
          },
        ],
      },
    );
    expect(out['gender'], 'female');
    expect(out['name'], [
      {
        'family': 'Okello',
        'given': ['Grace', 'A'],
      },
    ]);
  });

  test('implicit create resolves the type from the target element', () async {
    final out = await run(
      '''
$header
group main(source src : Patient, target tgt : Patient) {
  src.name as n -> tgt.name as t then {
    n.family as f -> t.text = f "r5";
  } "r6";
}
''',
      {
        'resourceType': 'Patient',
        'name': [
          {'family': 'Okello'},
        ],
      },
    );
    expect(out['name'], [
      {'text': 'Okello'},
    ]);
  });

  test('append, truncate, cast and uuid', () async {
    final out = await run(
      '''
$header
group main(source src : Patient, target tgt : Patient) {
  src.name as n -> tgt.name as t then {
    n.family as f -> t.text = append(f, ' ', 'x') "r7";
    n.family as f -> t.family = truncate(f, 3) "r8";
    n.given as g -> t.use = cast(g, 'code') "r9";
  } "r10";
  src -> tgt.id = uuid() "r11";
}
''',
      {
        'resourceType': 'Patient',
        'name': [
          {
            'family': 'Okello',
            'given': ['usual'],
          },
        ],
      },
    );
    final name = (out['name'] as List).single as Map;
    expect(name['text'], 'Okello x');
    expect(name['family'], 'Oke');
    expect(name['use'], 'usual');
    expect(out['id'], matches(RegExp(r'^[0-9a-f-]{36}$')));
  });

  test('evaluate runs FHIRPath over the source', () async {
    final out = await run(
      '''
$header
group main(source src : Patient, target tgt : Patient) {
  src.name as n -> tgt.name as t then {
    n -> t.text = evaluate(n, family + ', ' + given.first()) "r12";
  } "r13";
}
''',
      {
        'resourceType': 'Patient',
        'name': [
          {
            'family': 'Okello',
            'given': ['Grace'],
          },
        ],
      },
    );
    expect(out['name'], [
      {'text': 'Okello, Grace'},
    ]);
  });

  test('where filters, check throws, listMode first/last', () async {
    const src = {
      'resourceType': 'Patient',
      'name': [
        {'family': 'A', 'use': 'old'},
        {'family': 'B', 'use': 'official'},
        {'family': 'C', 'use': 'official'},
      ],
    };
    final out = await run('''
$header
group main(source src : Patient, target tgt : Patient) {
  src.name as n where use = 'official' -> tgt.name as t then {
    n.family as f -> t.family = f "r15";
  } "r16";
}
''', src);
    expect(out['name'], [
      {'family': 'B'},
      {'family': 'C'},
    ]);

    final first = await run('''
$header
group main(source src : Patient, target tgt : Patient) {
  src.name first as n -> tgt.name as t then { n.family as f -> t.family = f; };
}
''', src);
    expect(first['name'], [
      {'family': 'A'},
    ]);

    final last = await run('''
$header
group main(source src : Patient, target tgt : Patient) {
  src.name last as n -> tgt.name as t then { n.family as f -> t.family = f; };
}
''', src);
    expect(last['name'], [
      {'family': 'C'},
    ]);

    final failed = await run('''
$header
group main(source src : Patient, target tgt : Patient) {
  src.name as n check use = 'official' -> tgt.name as t then {
    n.family as f -> t.family = f "r17";
  } "r18";
}
''', src);
    expect(failed['resourceType'], 'OperationOutcome');
    expect(
      ((failed['issue'] as List).single as Map)['diagnostics'],
      contains('Check condition failed'),
    );
  });

  test('dependent group by name, with its own inputs', () async {
    final out = await run(
      '''
$header
group main(source src : Patient, target tgt : Patient) {
  src.name as n -> tgt.name as t then name(n, t) "r19";
}
group name(source n : HumanName, target t : HumanName) {
  n.family as f -> t.family = f "r20";
}
''',
      {
        'resourceType': 'Patient',
        'name': [
          {'family': 'Okello'},
        ],
      },
    );
    expect(out['name'], [
      {'family': 'Okello'},
    ]);
  });

  test('a types group is matched by source and target type', () async {
    // A bare `create()` on a target with a variable, and no rules of its
    // own, is resolved by the source and target types (the reference
    // engine's executeRule: transform CREATE with no parameter).
    final out = await run(
      '''
$header
group main(source src : Patient, target tgt : Patient) {
  src.name as n -> tgt.name = create() as t "r21";
}
group name(source n : HumanName, target t : HumanName) <<types>> {
  n.family as f -> t.family = f "r22";
}
''',
      {
        'resourceType': 'Patient',
        'name': [
          {'family': 'Okello'},
        ],
      },
    );
    expect(out['name'], [
      {'family': 'Okello'},
    ]);
  });

  test('extends runs the parent group first', () async {
    // The transform enters the map's first group (the reference engine's
    // `map.getGroup().get(0)`), so `main` comes first and `base` after.
    final out = await run(
      '''
$header
group main(source src : Patient, target tgt : Patient) extends base {
  src.active as a -> tgt.active = a "r24";
}
group base(source src : Patient, target tgt : Patient) {
  src.gender as g -> tgt.gender = g "r23";
}
''',
      {'resourceType': 'Patient', 'gender': 'male', 'active': true},
    );
    expect(out['gender'], 'male');
    expect(out['active'], true);
  });

  test('c and cc build a Coding and a CodeableConcept', () async {
    final out = await run(
      '''
$header
group main(source src : Patient, target tgt : Patient) {
  src -> tgt.maritalStatus = cc('http://example.org/cs', 'M') "r25";
}
''',
      {'resourceType': 'Patient'},
    );
    expect(out['maritalStatus'], {
      'coding': [
        {'system': 'http://example.org/cs', 'code': 'M'},
      ],
    });
  });

  const conceptMap = '''
conceptmap "gender" {
  prefix s = "http://example.org/src"
  prefix t = "http://example.org/tgt"
  s:F == t:female
  s:M == t:male
}
''';

  test('translate a code through a contained ConceptMap', () async {
    final out = await run(
      '''
$mapLine
$conceptMap
$uses
group main(source src : Patient, target tgt : Patient) {
  src.gender as g -> tgt.gender = translate(g, '#gender', 'code') "r26";
}
''',
      {'resourceType': 'Patient', 'gender': 'F'},
    );
    expect(out['gender'], 'female');
  });

  test('translate a CodeableConcept source by its codings', () async {
    // The source element is a CodeableConcept: its `coding` is a list, and
    // the engine must look the codings up one by one (before this it only
    // handled a string or a single map, and a list fell through to
    // "No translation found").
    final out = await run(
      '''
$mapLine
$conceptMap
$uses
group main(source src : Patient, target tgt : Patient) {
  src.maritalStatus as m -> tgt.gender = translate(m, '#gender', 'code') "r27";
}
''',
      {
        'resourceType': 'Patient',
        'maritalStatus': {
          'coding': [
            {'system': 'http://example.org/other', 'code': 'F'},
            {'system': 'http://example.org/src', 'code': 'M'},
          ],
        },
      },
    );
    expect(out['gender'], 'male');
  });

  test('translate to a Coding returns system and code', () async {
    final out = await run(
      '''
$mapLine
$conceptMap
$uses
group main(source src : Patient, target tgt : Patient) {
  src.gender as g -> tgt.maritalStatus as mc then {
    g -> mc.coding = translate(g, '#gender', 'Coding') "r28";
  } "r29";
}
''',
      {'resourceType': 'Patient', 'gender': 'M'},
    );
    expect(out['maritalStatus'], {
      'coding': [
        {'system': 'http://example.org/tgt', 'code': 'male'},
      ],
    });
  });

  test('a created resource gets an id, and reference points at it', () async {
    final out = await run(
      '''
map "http://example.org/StructureMap/b" = "b"
uses "http://hl7.org/fhir/StructureDefinition/Patient" as source
uses "http://hl7.org/fhir/StructureDefinition/Bundle" as target
group main(source src : Patient, target tgt : Bundle) {
  src -> tgt.type = 'collection' "r30";
  src -> tgt.entry as e, e.resource = create('Observation') as o then {
    src -> o.status = 'final' "r31";
    src -> o.subject as s, s.reference = reference(o) "r32";
  } "r33";
}
''',
      {'resourceType': 'Patient'},
      'Bundle',
    );
    final obs = ((out['entry'] as List).single as Map)['resource'] as Map;
    expect(obs['resourceType'], 'Observation');
    expect(obs['id'], isNotNull);
    expect((obs['subject'] as Map)['reference'], 'Observation/${obs['id']}');
  });

  test('a failing map returns an OperationOutcome naming the rule', () async {
    final out = await run(
      '''
$header
group main(source src : Patient, target tgt : Patient) {
  src.gender as g -> tgt.gender = translate(g, '#missing', 'code') "r34";
  src.gender as g -> tgt.name = g "r35";
}
''',
      {'resourceType': 'Patient', 'gender': 'F'},
    );
    expect(out['resourceType'], 'OperationOutcome');
    expect(
      ((out['issue'] as List).single as Map)['diagnostics'],
      contains('takes a HumanName'),
    );
  });

  test('helper runs a map into a fresh target of the group type', () async {
    final map = parser.parse('''
$header
group main(source src : Patient, target tgt : Patient) {
  src.gender as g -> tgt.gender = g "r36";
}
''', 'test');
    final out = await fhirMappingEngine(
      model,
      JsonNodeBuilder.resource({'resourceType': 'Patient', 'gender': 'other'}),
      map,
      cache,
      null,
    );
    expect(model.toJson(out! as JsonNode)['gender'], 'other');
  });
}
