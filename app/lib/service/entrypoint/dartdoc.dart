// Copyright (c) 2017, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:isolate';

import 'package:args/command_runner.dart';
import 'package:logging/logging.dart';
import 'package:pub_dev/tool/tracer/tracer.dart';

import '../../dartdoc/dartdoc_runner.dart';
import '../../dartdoc/handlers.dart';
import '../../job/backend.dart';
import '../../job/job.dart';
import '../../shared/configuration.dart';
import '../../shared/datastore.dart';
import '../../shared/handler_helpers.dart';
import '../../shared/popularity_storage.dart';
import '../../shared/scheduler_stats.dart';
import '../../tool/neat_task/pub_dev_tasks.dart';

import '../services.dart';

import '_isolate.dart';

final Logger logger = Logger('pub.dartdoc');

class DartdocCommand extends Command {
  @override
  String get name => 'dartdoc';

  @override
  String get description => 'The dartdoc service entrypoint.';

  @override
  Future<void> run() async {
    // Ensure that we're running in the right environment, or is running locally
    if (envConfig.gaeService != null && envConfig.gaeService != name) {
      throw StateError(
        'Cannot start "$name" in "${envConfig.gaeService}" environment',
      );
    }

    await startIsolates(
      logger: logger,
      frontendEntryPoint: _frontendMain,
      workerEntryPoint: _workerMain,
      deadWorkerTimeout: Duration(hours: 1),
    );
  }
}

Future _frontendMain(FrontendEntryMessage message) async {
  final statsConsumer = ReceivePort();
  registerSchedulerStatsStream(statsConsumer.cast<Map>());
  message.protocolSendPort.send(FrontendProtocolMessage(
    statsConsumerPort: statsConsumer.sendPort,
  ));

  await withServices(() async {
    await runHandler(logger, dartdocServiceHandler);
  });
}

Future _workerMain(WorkerEntryMessage message) async {
  message.protocolSendPort.send(WorkerProtocolMessage());

  await withServices(() async {
    setupDartdocPeriodicTasks();
    await popularityStorage.init();

    final jobProcessor = DartdocJobProcessor(
      aliveCallback: () => message.aliveSendPort.send(null),
    );
    await jobProcessor.generateDocsForSdk();

    final jobMaintenance = JobMaintenance(dbService, jobProcessor);

    Timer.periodic(const Duration(minutes: 15), (_) async {
      message.statsSendPort.send({
        'backend': await jobBackend.stats(JobService.dartdoc),
        'processor': jobProcessor.stats(),
        'traces': traceAggregator.asSortedMap(),
      });
    });

    await jobMaintenance.run();
  });
}
