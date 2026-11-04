import 'dart:convert';
import 'dart:io';
import 'package:ocs_bridge/services/bridge_server.dart';

void main(List<String> args) {
  final destination = args.firstOrNull ?? 'build/ocs-wrapper.test.json';
  final file = File(destination)..parent.createSync(recursive: true);
  file.writeAsStringSync(
    const JsonEncoder.withIndent(
      '  ',
    ).convert(ocsWrappers(15318, 'contract-test-token-not-for-production')),
  );
}
