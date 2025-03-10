// Copyright (c) 2019, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import '../../package/models.dart' show PackageView;
import '../../service/youtube/backend.dart' show PkgOfWeekVideo;
import '../../shared/tags.dart';
import '../../shared/urls.dart' as urls;

import '_cache.dart';
import '_utils.dart';
import 'layout.dart';

/// Renders the `views/page/landing.mustache` template.
String renderLandingPage({
  List<PackageView> ffPackages,
  List<PackageView> mostPopularPackages,
  List<PackageView> topFlutterPackages,
  List<PackageView> topDartPackages,
  List<PkgOfWeekVideo> topPoWVideos,
}) {
  bool isNotEmptyList(List l) => l != null && l.isNotEmpty;
  String renderMiniListIf(bool cond, List<PackageView> packages) =>
      cond ? renderMiniList(packages) : null;

  final hasFF = isNotEmptyList(ffPackages);
  final hasMostPopular = isNotEmptyList(mostPopularPackages);
  final hasTopFlutter = isNotEmptyList(topFlutterPackages);
  final hasTopDart = isNotEmptyList(topDartPackages);
  final hasPoW = isNotEmptyList(topPoWVideos);
  final values = {
    'has_ff': hasFF,
    'ff_mini_list_html': renderMiniListIf(hasFF, ffPackages),
    'ff_view_all_url': '/flutter/favorites',
    'has_mp': hasMostPopular,
    'mp_mini_list_html': renderMiniListIf(hasMostPopular, mostPopularPackages),
    'mp_view_all_url': urls.searchUrl(order: urls.SearchOrder.popularity),
    'has_tf': hasTopFlutter,
    'tf_mini_list_html': renderMiniListIf(hasTopFlutter, topFlutterPackages),
    'tf_view_all_url': urls.searchUrl(sdk: SdkTagValue.flutter),
    'has_td': hasTopDart,
    'td_mini_list_html': renderMiniListIf(hasTopDart, topDartPackages),
    'td_view_all_url': urls.searchUrl(sdk: SdkTagValue.dart),
    'has_pow': hasPoW,
    'pow_mini_list_html': hasPoW ? _renderPoW(topPoWVideos) : null,
  };
  final content = templateCache.renderTemplate('landing/page', values);
  return renderLayoutPage(
    PageType.landing,
    content,
    title: 'Dart packages',
    canonicalUrl: '/',
    mainClasses: ['landing-main'],
  );
}

String _renderPoW(List<PkgOfWeekVideo> videos) {
  return templateCache.renderTemplate('landing/pow_video_list', {
    'videos': videos
        .map((v) => {
              'video_url': htmlAttrEscape.convert(v.videoUrl),
              'title': v.title,
              'description': v.description,
              'thumbnail_url': htmlAttrEscape.convert(v.thumbnailUrl),
            })
        .toList(),
  });
}

/// Renders the `views/pkg/mini_list.mustache` template.
String renderMiniList(List<PackageView> packages) {
  final values = {
    'packages': packages.map((package) {
      return {
        'name': package.name,
        'publisher_id': package.publisherId,
        'package_url': urls.pkgPageUrl(package.name),
        'ellipsized_description': package.ellipsizedDescription,
      };
    }).toList(),
  };
  return templateCache.renderTemplate('landing/mini_list', values);
}
