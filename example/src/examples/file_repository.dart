// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:convert' as convert;
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:pub_server/repository.dart';
import 'package:yaml/yaml.dart';

final Logger _logger = Logger('pub_server.file_repository');

/// Implements the [PackageRepository] by storing pub packages on a file system.
/// 通过将pub包存储在文件系统的方式，实现[PackageRepository]抽象类。
class FileRepository extends PackageRepository {
  final String baseDir;

  FileRepository(this.baseDir);

  @override
  Stream<PackageVersion> versions(String package) {
    var directory = Directory(p.join(baseDir, package));
    if (directory.existsSync()) {
      return directory
          .list(recursive: false)
          .where((fse) => fse is Directory)
          .map((dir) {
        var version = p.basename(dir.path);
        var pubspecFile = File(pubspecFilePath(package, version));
        var tarballFile = File(packageTarballPath(package, version));
        if (pubspecFile.existsSync() && tarballFile.existsSync()) {
          var pubspec = pubspecFile.readAsStringSync();
          return PackageVersion(package, version, pubspec);
        }
        return null;
      }).where((e) => e != null);
    }

    return Stream.fromIterable([]);
  }

  // TODO: Could be optimized by searching for the exact package/version
  // combination instead of enumerating all.
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

  @override
  bool get supportsUpload => true;

  /// 上传请求处理器
  /// 如果下载得到的tar包中不存在`pubspec.yaml`文件，则抛出异常。
  @override
  Future<PackageVersion> upload(Stream<List<int>> data) async {
    _logger.info('Start uploading package.');
    // 接收流数据
    var bb = await data.fold(
        BytesBuilder(), (BytesBuilder byteBuilder, d) => byteBuilder..add(d));
    var tarballBytes = bb.takeBytes();
    // gzip解压
    var tarBytes = GZipDecoder().decodeBytes(tarballBytes);
    // tar解码
    var archive = TarDecoder().decodeBytes(tarBytes);
    ArchiveFile pubspecArchiveFile;
    for (var file in archive.files) {
      if (file.name == 'pubspec.yaml') {
        pubspecArchiveFile = file;
        break;
      }
    }

    // pubspec.yaml文件不存在，抛出异常
    if (pubspecArchiveFile == null) {
      throw 'Did not find any pubspec.yaml file in upload. Aborting.';
    }

    // TODO: Error handling.
    // TODO: yaml文件解析异常需要处理
    var pubspec = loadYaml(convert.utf8.decode(_getBytes(pubspecArchiveFile)));

    var package = pubspec['name'] as String;
    var version = pubspec['version'] as String;

    // 将基础目录，包名，版本号拼接成存储目标目录
    var packageVersionDir = Directory(p.join(baseDir, package, version));

    // 目录不存在则创建
    if (!packageVersionDir.existsSync()) {
      packageVersionDir.createSync(recursive: true);
    }

    // 若指定目录下已存在描述文件，则抛出异常
    var pubspecFile = File(pubspecFilePath(package, version));
    if (pubspecFile.existsSync()) {
      throw StateError('`$package` already exists at version `$version`.');
    }

    // 先单独保存描述文件
    var pubspecContent = convert.utf8.decode(_getBytes(pubspecArchiveFile));
    pubspecFile.writeAsStringSync(pubspecContent);
    // 再保存tar压缩包文件
    File(packageTarballPath(package, version)).writeAsBytesSync(tarballBytes);

    _logger.info('Uploaded new $package/$version');

    // 成功后返回包信息
    return PackageVersion(package, version, pubspecContent);
  }

  @override
  bool get supportsDownloadUrl => false;

  /// 下载请求解析器。
  /// 如果参数中指定的package和version不存在，则会抛出异常。
  @override
  Future<Stream<List<int>>> download(String package, String version) async {
    // 获取pub描述文件
    var pubspecFile = File(pubspecFilePath(package, version));
    // 获取tar压缩包文件
    var tarballFile = File(packageTarballPath(package, version));

    // 两个文件必须全部存在
    if (pubspecFile.existsSync() && tarballFile.existsSync()) {
      // 返回读取文件流
      return tarballFile.openRead();
    } else {
      throw 'package cannot be downloaded, because it does not exist';
    }
  }

  String pubspecFilePath(String package, String version) =>
      p.join(baseDir, package, version, 'pubspec.yaml');

  String packageTarballPath(String package, String version) =>
      p.join(baseDir, package, version, 'package.tar.gz');
}

// Since pkg/archive v1.0.31, content is `dynamic` although in our use case
// it's always `List<int>`
List<int> _getBytes(ArchiveFile file) => file.content as List<int>;
