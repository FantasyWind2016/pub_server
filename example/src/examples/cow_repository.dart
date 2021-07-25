// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library pub_server.copy_and_write_repository;

import 'dart:async';

import 'package:logging/logging.dart';
import 'package:pub_server/repository.dart';

/// 该操作会创建`pub_server`和`cow_repository`两个Logger对象。
/// 其中`pub_server`的`parent`对象是[Logger.root]，`cow_repository`的`parent`对象是`pub_server`。
final Logger _logger = Logger('pub_server.cow_repository');

/// A [CopyAndWriteRepository] writes to one repository and directs
/// read-misses to another repository.
///
/// Package versions not available from the read-write repository will be
/// fetched from a read-fallback repository and uploaded to the read-write
/// repository. This effectively caches all packages requested through this
/// [CopyAndWriteRepository].
///
/// New package versions which get uploaded will be stored only locally.
/// 
/// [CopyAndWriteRepository]类，将pub包写入到一个存储库local，并将未读取到pub包的读取请求转发到另一个存储库remote。
/// 在可读写库local中不存在的package包版本，将会从remote库中查询，并存储到local库中。
/// 这将会把所有通过[CopyAndWriteRepository]的请求结果缓存下来。
/// 
/// 上传的新的包版本，只会存储在local中。
class CopyAndWriteRepository extends PackageRepository {
  final PackageRepository local;
  final PackageRepository remote;
  final _RemoteMetadataCache _localCache;
  final _RemoteMetadataCache _remoteCache;
  final bool standalone;

  /// Construct a new proxy with [local] as the local [PackageRepository] which
  /// is used for uploading new package versions to and [remote] as the
  /// read-only [PackageRepository] which is consulted on misses in [local].
  /// 本地存储库缓存和远程存储库缓存都是使用的[_RemoteMetadataCache]类实例，区别是持有的存储库实例不同。
  CopyAndWriteRepository(
      PackageRepository local, PackageRepository remote, bool standalone)
      : local = local,
        remote = remote,
        standalone = standalone,
        _localCache = _RemoteMetadataCache(local),
        _remoteCache = _RemoteMetadataCache(remote);

  /// 查询包的所有版本信息。
  /// return [Stream]
  @override
  Stream<PackageVersion> versions(String package) {
    StreamController<PackageVersion> controller;
    void onListen() {
      // 先从本地缓存中读取版本列表
      var waitList = [_localCache.fetchVersionlist(package)];
      // 若standalone为false，则从远程缓存中读取版本列表
      if (standalone != true) {
        waitList.add(_remoteCache.fetchVersionlist(package));
      }
      // 等待所有异步请求完成
      Future.wait(waitList).then((tuple) {
        var versions = <PackageVersion>{}..addAll(tuple[0]);
        if (standalone != true) {
          versions.addAll(tuple[1]);
        }
        // 将所有版本取出，并传入Stream中
        // 但是这里没有把版本去重？
        for (var version in versions) {
          controller.add(version);
        }
        controller.close();
      });
    }

    controller = StreamController(onListen: onListen);
    return controller.stream;
  }

  /// 查找指定包名指定版本的Package版本信息
  @override
  Future<PackageVersion> lookupVersion(String package, String version) {
    return versions(package)
        .where((pv) => pv.versionString == version)
        .toList()
        .then((List<PackageVersion> versions) {
      if (versions.isNotEmpty) return versions.first;
      return null;
    });
  }

  /// 下载请求处理器
  @override
  Future<Stream<List<int>>> download(String package, String version) async {
    // 查找pub包版本
    var packageVersion = await local.lookupVersion(package, version);

    if (packageVersion != null) {
      // 从local存储库下载
      _logger.info('Serving $package/$version from local repository.');
      return local.download(package, packageVersion.versionString);
    } else {
      // We first download the package from the remote repository and store
      // it locally. Then we read the local version and return it.
      // 首先从远程存储库下载并且存在本地。然后读取版本存储的版本并返回。

      _logger.info('Downloading $package/$version from remote repository.');
      var stream = await remote.download(package, version);

      _logger.info('Upload $package/$version to local repository.');
      await local.upload(stream);

      // 从local存储库下载
      _logger.info('Serving $package/$version from local repository.');
      return local.download(package, version);
    }
  }

  @override
  bool get supportsUpload => true;

  /// 上传。
  /// data：Steam
  @override
  Future<PackageVersion> upload(Stream<List<int>> data) async {
    _logger.info('Starting upload to local package repository.');
    // 调用local的上传api
    final pkgVersion = await local.upload(data);
    // TODO: It's not really necessary to invalidate all.
    _logger.info(
        'Upload finished - ${pkgVersion.packageName}@${pkgVersion.version}. '
        'Invalidating in-memory cache.');
    // 上传成功后清空所有缓存
    _localCache.invalidateAll();
    return pkgVersion;
  }

  @override
  bool get supportsAsyncUpload => false;
}

/// A cache for [PackageVersion] objects for a given `package`.
///
/// The constructor takes a [PackageRepository] which will be used to populate
/// the cache.
class _RemoteMetadataCache {
  final PackageRepository remote;

  final Map<String, Set<PackageVersion>> _versions = {};
  final Map<String, Completer<Set<PackageVersion>>> _versionCompleters = {};

  _RemoteMetadataCache(this.remote);

  /// TODO: After a cache expiration we should invalidate entries and re-fetch them.
  /// TODO: 当一个缓存失效后，应该移除实体并重新获取
  /// 查询版本列表。
  Future<List<PackageVersion>> fetchVersionlist(String package) {
    return _versionCompleters
        .putIfAbsent(package, () {
          var c = Completer<Set<PackageVersion>>();

          _versions.putIfAbsent(package, () => <PackageVersion>{});
          // 从存储库中查询package的版本列表，比去年各放到缓存map中
          // TODO: 当前只是缓存类，应该只有缓存的读写，感觉查询操作不应该放在这里？
          remote.versions(package).toList().then((versions) {
            _versions[package].addAll(versions);
            c.complete(_versions[package]);
          });

          return c;
        })
        .future
        .then((set) => set.toList());
  }

  void addVersion(String package, PackageVersion version) {
    _versions
        .putIfAbsent(version.packageName, () => <PackageVersion>{})
        .add(version);
  }

  void invalidateAll() {
    _versionCompleters.clear();
    _versions.clear();
  }
}
