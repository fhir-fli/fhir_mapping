## 0.13.1

- **The `///` metadata lines may come before the `map` line** (#2), as the
  SDOHCC implementation guide's maps write them; the parser threw on them.
- **The header description drops empty comment lines, and a group always
  writes its rule list** (#1). R4B `StructureMap.group.rule` is 1..*; a
  group with no rules wrote none. Measured against the 73 published
  map/StructureMap pairs restored in fhir_r4_mapping's tests.

## 0.13.0

- First release. The parser (`StructureMapParser`), the engine
  (`FhirMapEngine`, `fhirMappingEngine`), `MappingVariables`, the
  definition resolver and the FHIRPath host services, moved out of
  fhir_r4_mapping / fhir_r5_mapping / fhir_r6_mapping, which become bindings
  over it.
- `FhirNodeBuilder`: the mutable node contract the engine writes through;
  `MappingModel<R>`: what a version supplies (builders, fhir_path binding,
  version spellings).
- Maps and ConceptMaps are read by element name (`MapView`, `GroupView`,
  `RuleView`, `ConceptMapView` …); per-node caches are keyed by node
  identity (the typed engine stored them in builder user data whose setter
  returned a copy, so nothing was ever cached).
- Parser, per the Java reference: the old-format header's comment block is
  the map's description; `/// experimental` is read; a bare
  `/// status = draft` is accepted (published maps write it unquoted);
  quoted rule names keep their hyphens in R4B and lose them in R5 and R6
  (`fixName`).
- Engine: `translate` over a CodeableConcept source looks the codings up one
  by one (a list fell through to "No translation found").
- Tests run over a JSON stub model: the 58 published example maps round-trip
  to their JSON, and every transform is exercised.
