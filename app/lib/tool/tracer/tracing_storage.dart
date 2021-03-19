// Copyright (c) 2021, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';

import 'package:gcloud/storage.dart';

import 'tracer.dart';

class TracingStorage implements Storage {
  final Storage _storage;
  final Tracer _tracer;
  TracingStorage(this._storage, this._tracer);

  @override
  Bucket bucket(
    String bucketName, {
    PredefinedAcl defaultPredefinedObjectAcl,
    Acl defaultObjectAcl,
  }) {
    return TracingBucket(
      _storage.bucket(
        bucketName,
        defaultPredefinedObjectAcl: defaultPredefinedObjectAcl,
        defaultObjectAcl: defaultObjectAcl,
      ),
      _tracer,
    );
  }

  @override
  Future<bool> bucketExists(String bucketName) async {
    return await _tracer.trace(() => _storage.bucketExists(bucketName));
  }

  @override
  Future<BucketInfo> bucketInfo(String bucketName) async {
    return await _tracer.trace(() => _storage.bucketInfo(bucketName));
  }

  @override
  Future copyObject(String src, String dest) async {
    return await _tracer.trace(() => _storage.copyObject(src, dest));
  }

  @override
  Future createBucket(
    String bucketName, {
    PredefinedAcl predefinedAcl,
    Acl acl,
  }) async {
    return await _tracer.trace(() => _storage.createBucket(
          bucketName,
          predefinedAcl: predefinedAcl,
          acl: acl,
        ));
  }

  @override
  Future deleteBucket(String bucketName) async {
    return await _tracer.trace(() => _storage.deleteBucket(bucketName));
  }

  @override
  Stream<String> listBucketNames() async* {
    yield* _tracer.trace(() => _storage.listBucketNames());
  }

  @override
  Future<Page<String>> pageBucketNames({int pageSize = 50}) async {
    return await _tracer
        .trace(() => _storage.pageBucketNames(pageSize: pageSize));
  }
}

class TracingBucket implements Bucket {
  final Bucket _bucket;
  final Tracer _tracer;
  TracingBucket(this._bucket, this._tracer);

  @override
  String absoluteObjectName(String objectName) {
    return _bucket.absoluteObjectName(objectName);
  }

  @override
  String get bucketName => _bucket.bucketName;

  @override
  Future delete(String name) async {
    return await _tracer.trace(() => _bucket.delete(name));
  }

  @override
  Future<ObjectInfo> info(String name) async {
    return await _tracer.trace(() => _bucket.info(name));
  }

  @override
  Stream<BucketEntry> list({
    String prefix,
    String delimiter,
  }) async* {
    yield* _tracer.trace(() => list(prefix: prefix, delimiter: delimiter));
  }

  @override
  Future<Page<BucketEntry>> page({
    String prefix,
    String delimiter,
    int pageSize = 50,
  }) async {
    return await _tracer.trace(() => _bucket.page(
          prefix: prefix,
          delimiter: delimiter,
          pageSize: pageSize,
        ));
  }

  @override
  Stream<List<int>> read(
    String objectName, {
    int offset,
    int length,
  }) async* {
    yield* _tracer.trace(() => _bucket.read(
          objectName,
          offset: offset,
          length: length,
        ));
  }

  @override
  Future updateMetadata(String objectName, ObjectMetadata metadata) async {
    await _tracer.trace(() => _bucket.updateMetadata(objectName, metadata));
  }

  @override
  StreamSink<List<int>> write(
    String objectName, {
    int length,
    ObjectMetadata metadata,
    Acl acl,
    PredefinedAcl predefinedAcl,
    String contentType,
  }) {
    return _tracer.trace(() => _bucket.write(
          objectName,
          length: length,
          metadata: metadata,
          acl: acl,
          predefinedAcl: predefinedAcl,
          contentType: contentType,
        ));
  }

  @override
  Future<ObjectInfo> writeBytes(
    String name,
    List<int> bytes, {
    ObjectMetadata metadata,
    Acl acl,
    PredefinedAcl predefinedAcl,
    String contentType,
  }) async {
    return await _tracer.trace(() => _bucket.writeBytes(
          name,
          bytes,
          metadata: metadata,
          acl: acl,
          predefinedAcl: predefinedAcl,
          contentType: contentType,
        ));
  }
}
