// Copyright (c) 2020, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async' show FutureOr, StreamSubscription, Zone;
import 'dart:io';

import 'package:appengine/appengine.dart';
import 'package:fake_gcloud/mem_datastore.dart';
import 'package:fake_gcloud/mem_storage.dart';
import 'package:gcloud/service_scope.dart';
import 'package:gcloud/storage.dart';
import 'package:googleapis_auth/auth_io.dart' as auth;
import 'package:meta/meta.dart';
import 'package:pub_dev/fake/server/fake_storage_server.dart';
import 'package:pub_dev/service/csp/backend.dart';
import 'package:pub_dev/service/youtube/backend.dart';
import 'package:pub_dev/tool/tracer/tracer.dart';
import 'package:pub_dev/tool/tracer/tracing_datastore.dart';
import 'package:pub_dev/tool/tracer/tracing_storage.dart';

import '../account/backend.dart';
import '../account/consent_backend.dart';
import '../account/google_oauth2.dart';
import '../admin/backend.dart';
import '../analyzer/analyzer_client.dart';
import '../audit/backend.dart';
import '../dartdoc/backend.dart';
import '../dartdoc/dartdoc_client.dart';
import '../fake/backend/fake_auth_provider.dart';
import '../fake/backend/fake_domain_verifier.dart';
import '../fake/backend/fake_email_sender.dart';
import '../fake/backend/fake_upload_signer_service.dart';
import '../frontend/email_sender.dart';
import '../job/backend.dart';
import '../package/backend.dart';
import '../package/name_tracker.dart';
import '../package/search_adapter.dart';
import '../package/upload_signer_service.dart';
import '../publisher/backend.dart';
import '../publisher/domain_verifier.dart';
import '../scorecard/backend.dart';
import '../search/backend.dart';
import '../search/mem_index.dart';
import '../search/search_client.dart';
import '../search/updater.dart';
import '../shared/configuration.dart';
import '../shared/datastore.dart';
import '../shared/popularity_storage.dart';
import '../shared/redis_cache.dart' show setupCache;
import '../shared/storage.dart';
import '../shared/urls.dart';
import '../shared/versions.dart';
import '../tool/utils/http.dart';

import 'announcement/backend.dart';
import 'secret/backend.dart';

final _pubDevServicesInitializedKey = '_pubDevServicesInitializedKey';

/// Run [fn] with services;
///
///  * AppEngine: storage and datastore,
///  * Redis cache, and,
///  * storage wrapped with retry.
Future<void> withServices(FutureOr<void> Function() fn) async {
  if (Zone.current[_pubDevServicesInitializedKey] == true) {
    return await fork(() async => await fn());
  }
  return withAppEngineServices(() async {
    return await fork(() async {
      // retrying auth client for storage service
      final authClient = await auth
          .clientViaApplicationDefaultCredentials(scopes: [...Storage.SCOPES]);
      final retryingAuthClient = httpRetryClient(innerClient: authClient);
      registerScopeExitCallback(() async => retryingAuthClient.close());

      // override storageService with retrying http client
      registerStorageService(
          Storage(retryingAuthClient, activeConfiguration.projectId));

      // register services with external dependencies
      registerAuthProvider(GoogleOauth2AuthProvider(
        <String>[
          activeConfiguration.pubClientAudience,
          activeConfiguration.pubSiteAudience,
          activeConfiguration.adminAudience,
        ],
      ));
      registerDomainVerifier(DomainVerifier());
      registerEmailSender(
        activeConfiguration.gmailRelayServiceAccount != null &&
                activeConfiguration.gmailRelayImpersonatedGSuiteUser != null
            ? createGmailRelaySender(
                activeConfiguration.gmailRelayServiceAccount,
                activeConfiguration.gmailRelayImpersonatedGSuiteUser,
              )
            : loggingEmailSender,
      );
      registerUploadSigner(await createUploadSigner(retryingAuthClient));

      return await _withPubServices(fn);
    });
  });
}

/// Run [fn] with services.
Future<void> withFakeServices({
  @required FutureOr<void> Function() fn,
  Configuration configuration,
  MemDatastore datastore,
  MemStorage storage,
}) async {
  if (Zone.current[_pubDevServicesInitializedKey] == true) {
    return await fork(() async => await fn());
  }
  if (!envConfig.isRunningLocally) {
    throw StateError("Mustn't use fake services inside AppEngine.");
  }
  datastore ??= MemDatastore();
  storage ??= MemStorage();
  return await fork(() async {
    registerDbService(DatastoreDB(datastore));
    registerStorageService(storage);
    if (configuration == null) {
      // start storage server
      final storageServer = FakeStorageServer(storage);
      await storageServer.start();
      registerScopeExitCallback(storageServer.close);

      // update configuration
      configuration = Configuration.test(
          storageBaseUrl: 'http://localhost:${storageServer.port}');
    }
    registerActiveConfiguration(configuration);

    // register fake services that would have external dependencies
    registerAuthProvider(FakeAuthProvider());
    registerDomainVerifier(FakeDomainVerifier());
    registerEmailSender(FakeEmailSender());
    registerUploadSigner(FakeUploadSignerService(configuration.storageBaseUrl));
    return await _withPubServices(() async {
      await youtubeBackend.update();
      return await fn();
    });
  });
}

/// Run [fn] with pub services that are shared between server instances, CLI
/// tools and integration tests.
Future<void> _withPubServices(FutureOr<void> Function() fn) async {
  return fork(() async {
    if (activeConfiguration.projectId != 'dartlang-pub'
        // && Platform.environment.containsKey('PUB_TRACER')
        ) {
      final rate = int.tryParse(Platform.environment['PUB_TRACER'] ?? '1') ?? 1;
      final tracer = SamplingTracer(rate: rate);
      registerDbService(
          DatastoreDB(TracingDatastore(dbService.datastore, tracer)));
      registerStorageService(TracingStorage(storageService, tracer));
      final traceSubscription = tracer.stream.listen(traceAggregator.add);
      registerScopeExitCallback(traceSubscription.cancel);
    }

    registerAccountBackend(AccountBackend(dbService));
    registerAdminBackend(AdminBackend(dbService));
    registerAnalyzerClient(AnalyzerClient());
    registerAnnouncementBackend(AnnouncementBackend());
    registerAuditBackend(AuditBackend(dbService));
    registerCspBackend(CspBackend());
    registerConsentBackend(ConsentBackend(dbService));
    registerDartdocBackend(
      DartdocBackend(
        dbService,
        await getOrCreateBucket(
            storageService, activeConfiguration.dartdocStorageBucketName),
      ),
    );
    registerDartdocClient(DartdocClient());
    registerDartSdkIndex(InMemoryPackageIndex.sdk(
        urlPrefix: dartSdkMainUrl(toolStableDartSdkVersion)));
    registerJobBackend(JobBackend(dbService));
    registerNameTracker(NameTracker(dbService));
    registerPackageIndex(InMemoryPackageIndex());
    registerIndexUpdater(IndexUpdater(dbService, packageIndex));
    registerPopularityStorage(
      PopularityStorage(await getOrCreateBucket(
          storageService, activeConfiguration.popularityDumpBucketName)),
    );
    registerPublisherBackend(PublisherBackend(dbService));
    registerScoreCardBackend(ScoreCardBackend(dbService));
    registerSearchBackend(SearchBackend(dbService));
    registerSearchClient(SearchClient());
    registerSearchAdapter(SearchAdapter());
    registerSecretBackend(SecretBackend(dbService));
    registerSnapshotStorage(SnapshotStorage(await getOrCreateBucket(
        storageService, activeConfiguration.searchSnapshotBucketName)));
    registerTarballStorage(
      TarballStorage(
          storageService,
          await getOrCreateBucket(
              storageService, activeConfiguration.packageBucketName),
          null),
    );
    registerYoutubeBackend(YoutubeBackend());

    // depends on previously registered services
    registerPackageBackend(PackageBackend(dbService, tarballStorage));
    await setupCache();

    registerScopeExitCallback(announcementBackend.close);
    registerScopeExitCallback(cspBackend.close);
    registerScopeExitCallback(() async => nameTracker.stopTracking());
    registerScopeExitCallback(snapshotStorage.close);
    registerScopeExitCallback(indexUpdater.close);
    registerScopeExitCallback(authProvider.close);
    registerScopeExitCallback(dartdocClient.close);
    registerScopeExitCallback(searchClient.close);
    registerScopeExitCallback(searchAdapter.close);
    registerScopeExitCallback(youtubeBackend.close);

    // Create a zone-local flag to indicate that services setup has been completed.
    return await fork(() => Zone.current.fork(zoneValues: {
          _pubDevServicesInitializedKey: true,
        }).run(() async => await fn()));
  });
}
