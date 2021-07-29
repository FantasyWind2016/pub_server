import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:pub_server/interceptor_middleware.dart';
import 'package:pub_server/repository.dart';
import 'package:shelf/shelf.dart';

typedef MsgBuilder = Map Function(PackageVersion packageVersion);

/// 企业微信机器人消息的中间件，封装了[interceptorMiddleware]。
/// 当`/api/packages/versions/newUpload`接口返回302时触发发送机器人消息。
/// qywxkey 企微开放平台的key，发送消息需要用到。
/// msgBuilder 自定义消息构造器，可以参照官方文档[https://work.weixin.qq.com/api/doc/90000/90136/91770]自定义消息的样式。
Middleware qywxRobotMiddleware(String qywxkey, {MsgBuilder msgBuilder}) {
  var builder = msgBuilder ?? defaultMsgBuilder;
  print('添加 qywxRobotMiddleware');
  return interceptorMiddleware(
    successHandler: (Request request, Response response) {
      var path = request.requestedUri.path;
      print('qywxRobotMiddleware.successHandler:$path,statusCode:${response.statusCode}');
      // 因为'/api/packages/versions/newUploadFinish'不包含版本信息，因此选择拦截上传请求
      if (path == '/api/packages/versions/newUpload') {
        if (response.statusCode == 302) {
          var context = response.context;
          if (context!=null) {
            var version = context['packageVersion'];
            if (version is PackageVersion) {
              var result = builder(version);
              if (!(result is Map)) {
                return;
              }
              var data = jsonEncode(result);
              // 调用企业微信机器人API，企业微信key由参数传入
              http.post(
                'https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=$qywxkey',
                headers: {
                  'Content-Type': 'application/json'
                },
                body: data,
              );
            }
          }
          
        }
      }
    }
  );
}

Map defaultMsgBuilder(PackageVersion packageVersion) {
  return {
    'msgtype': 'text',
    'text': {
      'content': 'OMG~我的天呐！Flutter Package ${packageVersion.packageName}的新品v${packageVersion.versionString}也太好看了吧！用它！用它！用它！',
      'mentioned_list': ['@all'],
    }
  };
}
