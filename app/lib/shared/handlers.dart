// Copyright (c) 2017, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:pub_dev/tool/tracer/tracer.dart';
import 'package:shelf/shelf.dart' as shelf;

import '../frontend/request_context.dart';

import 'popularity_storage.dart';
import 'scheduler_stats.dart';
import 'urls.dart' as urls;
import 'utils.dart' show eventLoopLatencyTracker, jsonUtf8Encoder;
import 'versions.dart';

const String default400BadRequest = '400 Bad Request';
const String default404NotFound = '404 Not Found';

/// The default age a browser would take hold of the static files before
/// checking with the server for a newer version.
const staticShortCache = Duration(minutes: 5);

/// The age the browser should cache the static file if there is a hash provided
/// and it matches the etag.
const staticLongCache = Duration(days: 7);

/// The default header values for JSON responses.
const jsonResponseHeaders = <String, String>{
  'content-type': 'application/json; charset="utf-8"',
  'x-content-type-options': 'nosniff',
};

final _logger = Logger('pub.shared.handler');
final _prettyJson = JsonUtf8Encoder('  ');

shelf.Response redirectResponse(String url) => shelf.Response.seeOther(url);

shelf.Response redirectToSearch(String query) {
  return redirectResponse(urls.searchUrl(q: query));
}

shelf.Response jsonResponse(
  Map map, {
  int status = 200,
  bool indentJson = false,
  Map<String, String> headers,
}) {
  final body = (indentJson || requestContext.indentJson)
      ? _prettyJson.convert(map)
      : jsonUtf8Encoder.convert(map);
  return shelf.Response(
    status,
    body: body,
    headers: {
      ...jsonResponseHeaders,
      if (headers != null) ...headers,
    },
  );
}

shelf.Response htmlResponse(
  String content, {
  int status = 200,
  Map<String, String> headers,
  bool noReferrer = false,
}) {
  headers ??= <String, String>{};
  headers['content-type'] = 'text/html; charset="utf-8"';
  headers['referrer-policy'] =
      noReferrer ? 'no-referrer' : 'no-referrer-when-downgrade';
  return shelf.Response(status, body: content, headers: headers);
}

shelf.Response badRequestHandler(shelf.Request request) =>
    htmlResponse(default400BadRequest, status: 400);

shelf.Response notFoundHandler(shelf.Request request,
        {String body = default404NotFound}) =>
    htmlResponse(body, status: 404);

shelf.Response rejectRobotsHandler(shelf.Request request) =>
    shelf.Response.ok('User-agent: *\nDisallow: /\n');

/// Combines a response for /debug requests
shelf.Response debugResponse([Map<String, dynamic> data]) {
  final map = <String, dynamic>{
    'env': {
      'GAE_VERSION': Platform.environment['GAE_VERSION'],
      'GAE_MEMORY_MB': Platform.environment['GAE_MEMORY_MB'],
    },
    'vm': {
      'currentRss': ProcessInfo.currentRss,
      'maxRss': ProcessInfo.maxRss,
      'eventLoopLatencyMillis': {
        'median': eventLoopLatencyTracker.median?.inMilliseconds,
        'p90': eventLoopLatencyTracker.p90?.inMilliseconds,
        'p99': eventLoopLatencyTracker.p99?.inMilliseconds,
      },
    },
    'versions': {
      'runtime': runtimeVersion,
      'runtime-sdk': runtimeSdkVersion,
      'pana': panaVersion,
      'dartdoc': dartdocVersion,
      'stable': {
        'dart': toolStableDartSdkVersion,
        'flutter': toolStableFlutterSdkVersion,
      },
      'preview': {
        'dart': toolPreviewDartSdkVersion,
        'flutter': toolPreviewFlutterSdkVersion,
      }
    },
    'scheduler': latestSchedulerStats,
    'traces': traceAggregator.asSortedMap(),
  };
  if (data != null) {
    map.addAll(data);
  }
  if (popularityStorage != null) {
    map['popularity'] = {
      'fetched': popularityStorage.lastFetched?.toIso8601String(),
      'count': popularityStorage.count,
      'dateRange': popularityStorage.dateRange,
    };
  }
  return jsonResponse(map, indentJson: true);
}

bool isNotModified(shelf.Request request, DateTime lastModified, String etag) {
  DateTime ifModifiedSince;
  try {
    ifModifiedSince = request.ifModifiedSince;
  } on FormatException {
    _logger.info('invalid If-Modified-Since header');
    return false;
  }
  if (ifModifiedSince != null &&
      lastModified != null &&
      !lastModified.isAfter(ifModifiedSince)) {
    return true;
  }

  final ifNoneMatch = request.headers[HttpHeaders.ifNoneMatchHeader];
  if (ifNoneMatch != null && ifNoneMatch == etag) {
    return true;
  }

  return false;
}

extension RequestExt on shelf.Request {
  /// Returns true if the current request declares that it accepts the [encoding].
  ///
  /// NOTE: the method does not parses the header, only checks whether the String
  ///       value is present (or everything is accepted).
  bool acceptsEncoding(String encoding) {
    final accepting = headers[HttpHeaders.acceptEncodingHeader];
    return accepting == null ||
        accepting.contains('*') ||
        accepting.contains(encoding);
  }
}
