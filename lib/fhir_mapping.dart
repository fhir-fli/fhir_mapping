/// The FHIR Mapping Language for every FHIR version: a parser from map text
/// to a StructureMap, a renderer back to text, and the transform engine that
/// runs a StructureMap over a source to build a target.
///
/// The map is read by element name through the `fhir_node` contract. The
/// data being transformed is built through [FhirNodeBuilder], the mutable
/// side of that contract, which a version's generated builders implement;
/// a [MappingModel] (`fhir_r4_mapping`, `fhir_r5_mapping`,
/// `fhir_r6_mapping`) makes those builders, parses resources, and names the
/// few things that differ between versions' StructureMap and ConceptMap
/// shapes.
library;

export 'package:fhir_path/fhir_path.dart'
    show CanonicalResourceCache, OnlineResourceCache, ResourceCache;

export 'src/definition_resolver.dart';
export 'src/exceptions.dart';
export 'src/fhir_map_engine.dart';
export 'src/host_services.dart';
export 'src/map_views.dart';
export 'src/mapping_model.dart';
export 'src/mapping_variables.dart';
export 'src/node_builder.dart';
export 'src/structure_map_parser.dart';
