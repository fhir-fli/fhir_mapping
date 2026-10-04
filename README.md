# fhir_mapping

The FHIR Mapping Language, independent of FHIR version: a parser from map
text to a StructureMap and back, and the transform engine that runs a
StructureMap over a source to build a target.

The engine reads a StructureMap and its ConceptMaps by element name through
`package:fhir_node`, evaluates FHIRPath through `package:fhir_path`, and
builds the target through `FhirNodeBuilder`, the mutable side of the node
contract. A version binding (`fhir_r4_mapping`, `fhir_r5_mapping`,
`fhir_r6_mapping`) supplies a `MappingModel`: its generated builders, its
fhir_path binding, and the few places where the versions spell a
StructureMap or ConceptMap differently (R4B's `contextType`, `equivalence`
and `dependent.variable`; R5's `relationship` and `dependent.parameter`).

```dart
final parser = await StructureMapParser.create(model);
final map = parser.parse(mapText, 'my-map');
final engine = await FhirMapEngine.create(cache, model);
final target = await engine.transform('', source, map, null);
```

Use a binding for everyday work; it hands back typed resources. This package
is what the bindings share.

Ported from the Java reference implementation
(`org.hl7.fhir.r5.utils.structuremap.StructureMapUtilities`); comments in
the parser and engine cite it where a version differs.
