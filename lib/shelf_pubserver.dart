// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:convert' as convert;

import 'package:http_parser/http_parser.dart';
import 'package:logging/logging.dart';
import 'package:mime/mime.dart';
import 'package:pub_semver/pub_semver.dart' as semver;
import 'package:shelf/shelf.dart' as shelf;
import 'package:yaml/yaml.dart';

import 'repository.dart';

final Logger _logger = Logger('pubserver.shelf_pubserver');

// TODO: Error handling from [PackageRepo] class.
// Distinguish between:
//   - Unauthorized Error
//   - Version Already Exists Error
//   - Internal Server Error

/// A shelf handler for serving a pub [PackageRepository].
/// 一个服务于pub包存储库的处理框架。
///
/// The following API endpoints are provided by this shelf handler:
/// 这个处理框架提供了以下API接口：
///
///   * Getting information about all versions of a package.
///   * 获取一个包的所有版本信息。
///
///         GET /api/packages/<package-name>
///         [200 OK] [Content-Type: application/json]
///         {
///           "name" : "<package-name>",
///           "latest" : { ...},
///           "versions" : [
///             {
///               "version" : "<version>",
///               "archive_url" : "<download-url tar.gz>",
///               "pubspec" : {
///                 "author" : ...,
///                 "dependencies" : { ... },
///                 ...
///               },
///           },
///           ...
///           ],
///         }
///         or
///         [404 Not Found]
///
///   * Getting information about a specific (package, version) pair.
///   * 获取指定pub包指定版本的信息。
///
///         GET /api/packages/<package-name>/versions/<version-name>
///         [200 OK] [Content-Type: application/json]
///         {
///           "version" : "<version>",
///           "archive_url" : "<download-url tar.gz>",
///           "pubspec" : {
///             "author" : ...,
///             "dependencies" : { ... },
///             ...
///           },
///         }
///         or
///         [404 Not Found]
///
///   * Downloading package.
///   * 下载包。
///
///         GET /api/packages/<package-name>/versions/<version-name>.tar.gz
///         [200 OK] [Content-Type: octet-stream ??? FIXME ???]
///         or
///         [302 Found / Temporary Redirect]
///         Location: <new-location>
///         or
///         [404 Not Found]
///
///   * Uploading
///   * 上传包。
///
///         GET /api/packages/versions/new
///         Headers:
///           Authorization: Bearer <oauth2-token>
///         [200 OK]
///         {
///           "fields" : {
///               "a": "...",
///               "b": "...",
///               ...
///           },
///           "url" : "https://storage.googleapis.com"
///         }
///
///         POST "https://storage.googleapis.com"
///         Headers:
///           a: ...
///           b: ...
///           ...
///         <multipart> file package.tar.gz
///         [302 Found / Temporary Redirect]
///         Location: https://pub.dartlang.org/finishUploadUrl
///
///         GET https://pub.dartlang.org/finishUploadUrl
///         [200 OK]
///         {
///           "success" : {
///             "message": "Successfully uploaded package.",
///           },
///        }
///
///   * Adding a new uploader
///   * 添加一个新的上传者。
///
///         POST /api/packages/<package-name>/uploaders
///         email=<uploader-email>
///
///         [200 OK] [Content-Type: application/json]
///         or
///         [400 Client Error]
///
///   * Removing an existing uploader.
///   * 删除一个已存在的上传者。
///
///         DELETE /api/packages/<package-name>/uploaders/<uploader-email>
///         [200 OK] [Content-Type: application/json]
///         or
///         [400 Client Error]
///
///
/// It will use the pub [PackageRepository] given in the constructor to provide
/// this HTTP endpoint.
/// 构造器中传入的[repository]对象，将被用来提供这些HTTP接口服务。
class ShelfPubServer {
  static final RegExp _packageRegexp = RegExp(r'^/api/packages/([^/]+)$');

  static final RegExp _versionRegexp =
      RegExp(r'^/api/packages/([^/]+)/versions/([^/]+)$');

  static final RegExp _addUploaderRegexp =
      RegExp(r'^/api/packages/([^/]+)/uploaders$');

  static final RegExp _removeUploaderRegexp =
      RegExp(r'^/api/packages/([^/]+)/uploaders/([^/]+)$');

  static final RegExp _downloadRegexp =
      RegExp(r'^/packages/([^/]+)/versions/([^/]+)\.tar\.gz$');

  final PackageRepository repository;
  final PackageCache cache;

  ShelfPubServer(this.repository, {this.cache});

  /// HTTP请求处理器
  /// 处理器中抛出的异常由外面的`shelf_io`统一捕获处理。
  Future<shelf.Response> requestHandler(shelf.Request request) async {
    var path = request.requestedUri.path;
    if (request.method == 'GET') {
      // 正则匹配package下载请求path
      var downloadMatch = _downloadRegexp.matchAsPrefix(path);
      if (downloadMatch != null) {
        var package = Uri.decodeComponent(downloadMatch.group(1));
        var version = Uri.decodeComponent(downloadMatch.group(2));
        // 如果不是语义化版本号，则直接返回“错误版本”
        if (!isSemanticVersion(version)) return _invalidVersion(version);
        return _download(request.requestedUri, package, version);
      }

      // 正则匹配package信息请求path
      var packageMatch = _packageRegexp.matchAsPrefix(path);
      if (packageMatch != null) {
        // 解析获取包名
        var package = Uri.decodeComponent(packageMatch.group(1));
        return _listVersions(request.requestedUri, package);
      }

      // 正则匹配package版本信息请求path
      var versionMatch = _versionRegexp.matchAsPrefix(path);
      if (versionMatch != null) {
        // 解析获得包名
        var package = Uri.decodeComponent(versionMatch.group(1));
        // 解析获得版本
        var version = Uri.decodeComponent(versionMatch.group(2));
        // 如果不是语义化版本号，则直接返回“错误版本”
        if (!isSemanticVersion(version)) return _invalidVersion(version);
        return _showVersion(request.requestedUri, package, version);
      }

      // 生成新版本path
      if (path == '/api/packages/versions/new') {
        // 不支持上传则直接返回失败
        if (!repository.supportsUpload) {
          return shelf.Response.notFound(null);
        }

        // 是否支持异步上传。cow_repository不支持。
        if (repository.supportsAsyncUpload) {
          return _startUploadAsync(request.requestedUri);
        } else {
          // 返回 302：newUpload
          return _startUploadSimple(request.requestedUri);
        }
      }

      // 完成新上传path
      if (path == '/api/packages/versions/newUploadFinish') {
        // 不支持上传则直接返回失败
        if (!repository.supportsUpload) {
          return shelf.Response.notFound(null);
        }

        // 是否支持异步上传。cow_repository不支持。
        if (repository.supportsAsyncUpload) {
          return _finishUploadAsync(request.requestedUri);
        } else {
          return _finishUploadSimple(request.requestedUri);
        }
      }
    } else if (request.method == 'POST') {
      // 创建新上传path
      if (path == '/api/packages/versions/newUpload') {
        // 不支持上传则直接返回失败
        if (!repository.supportsUpload) {
          return shelf.Response.notFound(null);
        }

        // 简单上传
        return _uploadSimple(request.requestedUri,
            request.headers['content-type'], request.read());
      } else {
        // 不支持上传者管理则直接返回失败
        // 这个校验的位置貌似放错了？
        if (!repository.supportsUploaders) {
          return shelf.Response.notFound(null);
        }

        // 正则匹配新增上传者请求path
        var addUploaderMatch = _addUploaderRegexp.matchAsPrefix(path);
        if (addUploaderMatch != null) {
          var package = Uri.decodeComponent(addUploaderMatch.group(1));
          return request.readAsString().then((String body) {
            return _addUploader(package, body);
          });
        }
      }
    } else if (request.method == 'DELETE') {
      // 不支持上传者管理则直接返回失败
      // 这个校验的位置貌似放错了？
      if (!repository.supportsUploaders) {
        return shelf.Response.notFound(null);
      }

      // 正则匹配删除上传者请求path
      var removeUploaderMatch = _removeUploaderRegexp.matchAsPrefix(path);
      if (removeUploaderMatch != null) {
        var package = Uri.decodeComponent(removeUploaderMatch.group(1));
        var user = Uri.decodeComponent(removeUploaderMatch.group(2));
        // 删除上传者
        return removeUploader(package, user);
      }
    }
    return shelf.Response.notFound(null);
  }

  /// Metadata handlers.
  /// 获取包信息
  Future<shelf.Response> _listVersions(Uri uri, String package) async {
    if (cache != null) {
      // 如果缓存中存在，则从缓存中读取
      var binaryJson = await cache.getPackageData(package);
      if (binaryJson != null) {
        return _binaryJsonResponse(binaryJson);
      }
    }

    // 从存储库中读取版本信息
    var packageVersions = await repository.versions(package).toList();
    // 若无版本则返回未找到
    if (packageVersions.isEmpty) {
      return shelf.Response.notFound(null);
    }

    // 版本排序
    packageVersions.sort((a, b) => a.version.compareTo(b.version));

    // TODO: Add legacy entries (if necessary), such as version_url.
    // 将版本信息转化为json对象
    Map packageVersion2Json(PackageVersion version) {
      return {
        'archive_url':
            '${_downloadUrl(uri, version.packageName, version.versionString)}',
        'pubspec': loadYaml(version.pubspecYaml),
        'version': version.versionString,
      };
    }

    // 倒序遍历所有版本，获取最后一个非预发版本
    // 默认值是最后一个版本
    var latestVersion = packageVersions.last;
    for (var i = packageVersions.length - 1; i >= 0; i--) {
      if (!packageVersions[i].version.isPreRelease) {
        latestVersion = packageVersions[i];
        break;
      }
    }

    // TODO: The 'latest' is something we should get rid of, since it's duplicated in 'versions'.
    // TODO: lasted或许应该移除掉，因为它在versions里已经存在了。
    // 组装package信息json
    var binaryJson = convert.json.encoder.fuse(convert.utf8.encoder).convert({
      'name': package,
      'latest': packageVersion2Json(latestVersion),
      'versions': packageVersions.map(packageVersion2Json).toList(),
    });
    // 如果缓存存在，则设置缓存
    if (cache != null) {
      await cache.setPackageData(package, binaryJson);
    }
    // 返回信息
    return _binaryJsonResponse(binaryJson);
  }

  /// 获取指定包名指定版本的信息
  /// uri 网络请求uri
  /// package 包名
  /// version 版本号
  /// return 版本信息json，包括archive_url，pubspec内容，version
  Future<shelf.Response> _showVersion(
      Uri uri, String package, String version) async {
    // 查找指定版本信息
    var ver = await repository.lookupVersion(package, version);
    if (ver == null) {
      return shelf.Response.notFound(null);
    }

    // TODO: Add legacy entries (if necessary), such as version_url.
    return _jsonResponse({
      'archive_url': '${_downloadUrl(uri, ver.packageName, ver.versionString)}',
      'pubspec': loadYaml(ver.pubspecYaml),
      'version': ver.versionString,
    });
  }

  /// Download handlers.
  /// 下载请求处理器。
  Future<shelf.Response> _download(
      Uri uri, String package, String version) async {
    // 因为当前的repository是[CowRepository]，是不支持supportsDownloadUrl的，所以下面这个分支不会执行
    if (repository.supportsDownloadUrl) {
      var url = await repository.downloadUrl(package, version);
      // This is a redirect to [url]
      return shelf.Response.seeOther(url);
    }

    var stream = await repository.download(package, version);
    return shelf.Response.ok(stream);
  }

  /// Upload async handlers.
  /// 开始异步上传。
  Future<shelf.Response> _startUploadAsync(Uri uri) async {
    // cow_repository不支持startAsyncUpload
    var info = await repository.startAsyncUpload(_finishUploadAsyncUrl(uri));
    return _jsonResponse({
      'url': '${info.uri}',
      'fields': info.fields,
    });
  }

  /// 完成异步上传
  Future<shelf.Response> _finishUploadAsync(Uri uri) async {
    try {
      // cow_repository未实现
      final vers = await repository.finishAsyncUpload(uri);
      if (cache != null) {
        _logger.info('Invalidating cache for package ${vers.packageName}.');
        await cache.invalidatePackageData(vers.packageName);
      }
      return _jsonResponse({
        'success': {
          'message': 'Successfully uploaded package.',
        },
      });
    } on ClientSideProblem catch (error, stack) {
      _logger.info('A problem occured while finishing upload.', error, stack);
      return _jsonResponse({
        'error': {
          'message': '$error.',
        },
      }, status: 400);
    } catch (error, stack) {
      _logger.warning('An error occured while finishing upload.', error, stack);
      return _jsonResponse({
        'error': {
          'message': '$error.',
        },
      }, status: 500);
    }
  }

  /// Upload custom handlers.
  /// 开始简单上传，但是还没有实现？
  shelf.Response _startUploadSimple(Uri url) {
    _logger.info('Start simple upload.');
    return _jsonResponse({
      'url': '${_uploadSimpleUrl(url)}',
      'fields': {},
    });
  }

  /// 简单上传
  Future<shelf.Response> _uploadSimple(
      Uri uri, String contentType, Stream<List<int>> stream) async {
    _logger.info('Perform simple upload.');

    var boundary = _getBoundary(contentType);

    // boundary不能为空，否则直接返回错误
    if (boundary == null) {
      return _badRequest(
          'Upload must contain a multipart/form-data content type.');
    }

    // We have to listen to all multiparts: Just doing `parts.first` will
    // result in the cancellation of the subscription which causes
    // eventually a destruction of the socket, this is an odd side-effect.
    // What we would like to have is something like this:
    //     parts.expect(1).then((part) { upload(part); })
    MimeMultipart thePart;

    // boundary遍历所有part。只取第一个。
    await for (MimeMultipart part
        in stream.transform(MimeMultipartTransformer(boundary))) {
      // If we get more than one part, we'll ignore the rest of the input.
      if (thePart != null) {
        continue;
      }

      thePart = part;
    }

    try {
      // TODO: Ensure that `part.headers['content-disposition']` is `form-data; name="file"; filename="package.tar.gz`
      // TODO：确认header中包含file信息。
      // 上传part
      var version = await repository.upload(thePart);
      if (cache != null) {
        // cache如果存在则需要清除当前包缓存
        _logger.info('Invalidating cache for package ${version.packageName}.');
        await cache.invalidatePackageData(version.packageName);
      }
      _logger.info('Redirecting to found url.');
      // 返回302：结束简单上传URL
      return shelf.Response.found(_finishUploadSimpleUrl(uri), context: {
        'packageVersion': version,
      });
    } catch (error, stack) {
      _logger.warning('Error occured', error, stack);
      // TODO: Do error checking and return error codes?
      // TODO：目前直接返回的error信息，应该校验error类型并返回code
      return shelf.Response.found(
          _finishUploadSimpleUrl(uri, error: error.toString()));
    }
  }

  // 完成简单上传
  shelf.Response _finishUploadSimple(Uri uri) {
    // 解析error信息
    var error = uri.queryParameters['error'];
    if (error != null) {
      // error存在则返回上传失败
      _logger.info('Finish simple upload (error: $error).');
      return _badRequest(error);
    }
    // 返回上传成功。
    // TODO：这里可以增加拦截器触发点
    return _jsonResponse({
      'success': {'message': 'Successfully uploaded package.'}
    });
  }

  /// Uploader handlers.
  /// 新增上传者处理器。
  Future<shelf.Response> _addUploader(String package, String body) async {
    var parts = body.split('=');
    if (parts.length == 2 && parts[0] == 'email' && parts[1].isNotEmpty) {
      try {
        var user = Uri.decodeQueryComponent(parts[1]);
        await repository.addUploader(package, user);
        return _successfullRequest('Successfully added uploader to package.');
      } on UploaderAlreadyExistsException {
        return _badRequest(
            'Cannot add an already-existent uploader to package.');
      } on UnauthorizedAccessException {
        return _unauthorizedRequest();
      } on GenericProcessingException catch (e) {
        return _badRequest(e.message);
      }
    }
    return _badRequest('Invalid request');
  }

  /// 删除上传者处理器。
  Future<shelf.Response> removeUploader(
      String package, String userEmail) async {
    try {
      // 目前cow_repository不支持删除
      await repository.removeUploader(package, userEmail);
      return _successfullRequest('Successfully removed uploader from package.');
    } on LastUploaderRemoveException {
      return _badRequest('Cannot remove last uploader of a package.');
    } on UnauthorizedAccessException {
      return _unauthorizedRequest();
    } on GenericProcessingException catch (e) {
      return _badRequest(e.message);
    }
  }

  // Helper functions.

  shelf.Response _invalidVersion(String version) =>
      _badRequest('Version string "$version" is not a valid semantic version.');

  Future<shelf.Response> _successfullRequest(String message) async {
    return shelf.Response(200,
        body: convert.json.encode({
          'success': {'message': message}
        }),
        headers: {'content-type': 'application/json'});
  }

  shelf.Response _unauthorizedRequest() => shelf.Response(403,
      body: convert.json.encode({
        'error': {'message': 'Unauthorized request.'}
      }),
      headers: {'content-type': 'application/json'});

  shelf.Response _badRequest(String message) => shelf.Response(400,
      body: convert.json.encode({
        'error': {'message': message}
      }),
      headers: {'content-type': 'application/json'});

  shelf.Response _binaryJsonResponse(List<int> d, {int status = 200}) =>
      shelf.Response(status,
          body: Stream.fromIterable([d]),
          headers: {'content-type': 'application/json'});

  shelf.Response _jsonResponse(Map json, {int status = 200}) =>
      shelf.Response(status,
          body: convert.json.encode(json),
          headers: {'content-type': 'application/json'});

  /// Download urls.
  /// 组装指定package指定version下载地址
  Uri _downloadUrl(Uri url, String package, String version) {
    var encode = Uri.encodeComponent;
    return url.resolve(
        '/packages/${encode(package)}/versions/${encode(version)}.tar.gz');
  }

  // Upload async urls.

  Uri _finishUploadAsyncUrl(Uri url) =>
      url.resolve('/api/packages/versions/newUploadFinish');

  /// Upload custom urls.
  /// 简单上传URL地址
  Uri _uploadSimpleUrl(Uri url) =>
      url.resolve('/api/packages/versions/newUpload');

  /// 完成简单上传URL地址
  /// 这里奇怪的是错误信息竟然要放到302URL里返回？正常应该直接返回吧？还是说mutipart上传的请求无法返回
  /// 而且这里竟然不知道是哪个package的哪个版本成功了。(捂脸.png)
  Uri _finishUploadSimpleUrl(Uri url, {String error}) {
    var postfix = error == null ? '' : '?error=${Uri.encodeComponent(error)}';
    return url.resolve('/api/packages/versions/newUploadFinish$postfix');
  }

  /// 判断是否是语义版本号
  bool isSemanticVersion(String version) {
    try {
      semver.Version.parse(version);
      return true;
    } catch (_) {
      return false;
    }
  }
}

/// A cache for storing metadata for packages.
/// 存储包信息的缓存类。
abstract class PackageCache {
  Future setPackageData(String package, List<int> data);

  Future<List<int>> getPackageData(String package);

  Future invalidatePackageData(String package);
}

/// 从contentType获取boundary。
String _getBoundary(String contentType) {
  var mediaType = MediaType.parse(contentType);

  if (mediaType.type == 'multipart' && mediaType.subtype == 'form-data') {
    return mediaType.parameters['boundary'];
  }
  return null;
}
