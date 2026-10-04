import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:fhir_mapping/fhir_mapping.dart';
import 'package:test/test.dart';

import 'support/json_builder.dart';

/// Every published example map, parsed over the stub model, must give the
/// published JSON (R4B shape), element for element.
Future<void> main() async {
  final parser = await StructureMapParser.create(const StubMappingModel());
  final files =
      Directory('test/parser_examples')
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.json'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  test('all 58 published examples are present', () {
    expect(files.length, 58);
  });
  for (final file in files) {
    final expected =
        jsonDecode(file.readAsStringSync()) as Map<String, dynamic>
          ..remove('text')
          ..remove('meta');
    final mapText =
        File(file.path.replaceAll('.json', '.map')).readAsStringSync();
    test(file.path, () {
      final parsed = parser.parse(mapText, 'fhirmap');
      final ours =
          const StubMappingModel().toJson(parsed)
            ..remove('text')
            ..remove('meta');
      expect(
        const DeepCollectionEquality().equals(expected, ours),
        isTrue,
        reason: const JsonEncoder.withIndent('  ').convert(ours),
      );
    });
  }
}
