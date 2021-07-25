// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';

import 'dart:convert' as convert;
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:pub_server/repository.dart';

final Logger _logger = Logger('pub_server.http_proxy_repository');

/// Implements the [PackageRepository] by talking to a remote HTTP server via
/// the pub HTTP API.
///
/// This [PackageRepository] does not support uploading so far.
/// 通过pub的HTTP接口，和远程的HTTP服务器通讯，实现了[PackageRepository]抽象类。
/// 该类暂不支持上传功能。
class HttpProxyRepository extends PackageRepository {
  final http.Client client;
  final Uri baseUrl;

  HttpProxyRepository(this.client, this.baseUrl);

  @override
  Stream<PackageVersion> versions(String package) async* {
    var versionUrl =
        baseUrl.resolve('/api/packages/${Uri.encodeComponent(package)}');

    var response = await client.get(versionUrl);

    if (response.statusCode != 200) {
      return;
    }

    var json = convert.json.decode(response.body);
    var versions = json['versions'] as List<dynamic>;
    if (versions != null) {
      for (var item in versions) {
        var pubspec = item['pubspec'];
        var pubspecString = convert.json.encode(pubspec);
        yield PackageVersion(pubspec['name'] as String,
            pubspec['version'] as String, pubspecString);
      }
    }
  }

  // TODO: Could be optimized, since we don't need to list all versions and can
  // just talk to the HTTP endpoint which gives us a specific package/version
  // combination.
  @override
  Future<PackageVersion> lookupVersion(String package, String version) {
    return versions(package)
        .where((v) => v.packageName == package && v.versionString == version)
        .toList()
        .then((List<PackageVersion> versions) {
      if (versions.isNotEmpty) return versions.first;
      return null;
    });
  }

  @override
  bool get supportsUpload => false;

  @override
  bool get supportsAsyncUpload => false;

  @override
  bool get supportsDownloadUrl => true;

  /// 生成下载链接地址
  /// 将报名和版本拼接成tar压缩包的文件地址
  @override
  Future<Uri> downloadUrl(String package, String version) async {
    package = Uri.encodeComponent(package);
    version = Uri.encodeComponent(version);
    return baseUrl.resolve('/packages/$package/versions/$version.tar.gz');
  }

  /// 下载请求处理器
  @override
  Future<Stream<List<int>>> download(String package, String version) async {
    _logger.info('Downloading package $package/$version.');

    // 生成下载链接地址
    var url = await downloadUrl(package, version);
    // 发送下载http请求，返回值是Stream流，然后直接返回
    var response = await client.send(http.Request('GET', url));
    return response.stream;
  }
}
