// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:io';

import 'package:args/args.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:pub_server/shelf_pubserver.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

import 'src/examples/cow_repository.dart';
import 'src/examples/file_repository.dart';
import 'src/examples/http_proxy_repository.dart';
import 'src/middleware/qywx_robot_middleware.dart';

final Uri pubDartLangOrg = Uri.parse('https://pub.flutter-io.cn');

void main(List<String> args) {
  // 解析启动参数
  var parser = argsParser();
  var results = parser.parse(args);

  var directory = results['directory'] as String;
  var host = results['host'] as String;
  var port = int.parse(results['port'] as String);
  var qywxkey = results['qywxkey'] as String;
  var standalone = results['standalone'] as bool;

  if (results.rest.isNotEmpty) {
    print('Got unexpected arguments: "${results.rest.join(' ')}".\n\nUsage:\n');
    print(parser.usage);
    exit(1);
  }

  // 设置日志记录器
  setupLogger();
  // 启动pub服务器
  runPubServer(directory, host, port, qywxkey, standalone);
}

Future<HttpServer> runPubServer(
    String baseDir, String host, int port, String qywxkey, bool standalone) {
  var client = http.Client();

  // 本地文件存储库
  var local = FileRepository(baseDir);
  // 网络存储库
  var remote = HttpProxyRepository(client, pubDartLangOrg);
  // 复制和写入存储库
  var cow = CopyAndWriteRepository(local, remote, standalone);

  // 初始化pub服务框架，传入了存储库，但未传入cache对象，所以当前服务框架没有缓存
  // 但cow存储库中有缓存逻辑。
  var server = ShelfPubServer(cow);
  print('Listening on http://$host:$port\n'
      '\n'
      'To make the pub client use this repository configure your shell via:\n'
      '\n'
      '    \$ export PUB_HOSTED_URL=http://$host:$port\n'
      '\n');

  var pipeline = Pipeline();
  if (qywxkey!=null && qywxkey.isNotEmpty) {
    pipeline = pipeline.addMiddleware(qywxRobotMiddleware(qywxkey)); // 企业微信机器人中间件  
  }
  pipeline = pipeline.addMiddleware(logRequests()); // 日志中间件
  // 启动一个http服务
  return shelf_io.serve(
      pipeline.addHandler(server.requestHandler), // 请求处理器
      host,
      port);
}

ArgParser argsParser() {
  var parser = ArgParser();

  // 给参数解析器设置可支持的参数以及默认值
  parser.addOption('directory',
      abbr: 'd', defaultsTo: 'pub_server-repository-data');

  parser.addOption('host', abbr: 'h', defaultsTo: 'localhost');

  parser.addOption('port', abbr: 'p', defaultsTo: '8080');
  parser.addOption('qywxkey', abbr: 'q', defaultsTo: '');
  parser.addFlag('standalone', abbr: 's', defaultsTo: false);
  return parser;
}

void setupLogger() {
  Logger.root.onRecord.listen((LogRecord record) {
    var head = '${record.time} ${record.level} ${record.loggerName}';
    var tail = record.stackTrace != null ? '\n${record.stackTrace}' : '';
    print('$head ${record.message} $tail');
  });
}
