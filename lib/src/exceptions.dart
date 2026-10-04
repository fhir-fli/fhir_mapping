/// The base of what the mapping parser and engine throw: a message, the
/// exception that caused it when there was one, and where.
class FhirMappingException implements Exception {
  /// Creates the exception.
  FhirMappingException({this.message, this.cause, this.stackTrace});

  /// What went wrong.
  final String? message;

  /// The underlying error, when this wraps one.
  final Object? cause;

  /// Where it was thrown, when recorded.
  final StackTrace? stackTrace;

  @override
  String toString() {
    final buffer = StringBuffer();
    if (message != null) buffer.writeln('Message: $message');
    if (cause != null) buffer.writeln('Cause: $cause');
    if (stackTrace != null) buffer.writeln('StackTrace:\n$stackTrace');
    return buffer.toString();
  }
}

/// Exception thrown when there is an error parsing map text.
class FhirParserException extends FhirMappingException {
  /// Constructs a new [FhirParserException].
  FhirParserException({super.message, super.cause, super.stackTrace});
}

/// Exception thrown when casting a value to a different type.
class FHIRMappingCastException extends FhirMappingException {
  /// Constructs a new [FHIRMappingCastException].
  FHIRMappingCastException({super.message});
}

/// Exception thrown when a definition is incorrect
class MappingDefinitionException extends FhirMappingException {
  /// Constructs a new [MappingDefinitionException].
  MappingDefinitionException({super.message, super.cause, super.stackTrace});
}

/// Exception thrown when a lexer error occurs.
class FHIRMappingLexerException extends FhirMappingException {
  /// Constructs a new [FHIRMappingLexerException].
  FHIRMappingLexerException({super.message, super.cause, super.stackTrace});
}

/// Exception thrown when a terminology service is not available.
class NoTerminologyServiceException extends FhirMappingException {
  /// Constructor for [NoTerminologyServiceException] with optional [message]
  /// and [cause].
  NoTerminologyServiceException({super.message, super.cause});
}

/// Exception for when a ValueSet is too costly to expand
class ETooCostly implements Exception {
  /// Create an ETooCostly exception
  ETooCostly(this.message);

  /// The message to display
  final String message;

  @override
  String toString() => 'ETooCostly: $message';
}
