/// The harness-bridge module: the [HarnessGateway] seam and its Claude
/// Code implementation, the SSE/poll protocols, the quiet-wire lease and
/// reattach ladder, the shared turn pump, the persisted settings, and
/// the pure wording rules. Everything the phone knows about "the thing
/// on the other end" is here — a different coding harness only has to
/// implement [HarnessGateway] to plug in.
library;

export 'client.dart';
export 'gateway.dart';
export 'prefs.dart';
export 'text_rules.dart';
export 'transport.dart';
export 'turn_pump.dart';
export 'wire_lease.dart';
export 'bridge_event.dart';
