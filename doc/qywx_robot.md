# 给Flutter包私有仓库pub_server增加企业微信机器人消息

本文相关代码地址：[github](https://github.com/FantasyWind2016/pub_server)。  

效果：
![群机器人消息效果图](qywx_robot_result.png)

## 功能说明

默认的私有仓库`pub_server`服务程序在package上传成功后只是在命令行中输出了一行成功日志，缺少必要的消息通知，包发布成功了开发人员也不知道。  
因为工作中企业微信使用较多，而且其中的群机器人可以方便的在工作群中推送消息，因此想着将上传成功的消息通过群机器人推送到群中。  

企业微信群机器人的接入方法参看：[群机器人配置说明](https://work.weixin.qq.com/api/doc/90000/90136/91770)。  

## 代码分析

### 相关类

修改代码前还是先完整看了一下`pub_server`的实现代码。  

`shelf_pubserver.dart`文件`ShelfPubServer`类，该类负责服务端各接口的具体处理逻辑。在`requestHandler`方法中就可以得到每个接口的请求和反馈报文。其中package包上传功能涉及到`/api/packages/versions/newUpload`和`/api/packages/versions/newUploadFinish`两个接口，第一个接口的职责说具体的上传逻辑，第二个接口只是完成上传操作。第一个接口处理成功后会返回一个302请求，让客户端直接请求第二个接口。  

`cow_repository.dart`文件`CopyAndWriteRepository`类，该类是整个服务的核心，`ShelfPubServer`类所有的处理操作最终都是交给本类处理。其中，该类持有了`file_repository.dart`文件的`FileRepository`类负责实际的上传操作。  

理论上，在`ShelfPubServer`类、`CopyAndWriteRepository`类、`FileRepository`类这三个类的相关代码中我们都可以监控到package上传成功的消息，可以在相关的代码位置向企业微信的群机器人发送消息请求。  

### 初始方案

我原本是计划在`ShelfPubServer`类的`_finishUploadSimple`方法中，`/api/packages/versions/newUploadFinish`接口返回`Successfully uploaded package.`信息时直接发送机器人消息。  
但是后面发现两个问题：第一，在`/api/packages/versions/newUploadFinish`接口的请求参数中并未携带上传的package包的信息，所以没办法发送相关的通知文本；第二，在`ShelfPubServer`类的代码中塞入给群机器人发送消息的代码就污染了原本逻辑代码，造成了不必要的代码耦合，如果我们后面需要增加邮件通知、钉钉通知，那是不是还要新增代码？  

其中第一个问题可以通过修改`/api/packages/versions/newUpload`接口返回报文的方法实现，不过算是对原逻辑代码的改动，暂时不采用；思考第二个问题时，准备自己实现一个请求处理拦截器进行代码解耦，然后发现了一段代码：  

```Dart
  // 启动一个http服务
  return shelf_io.serve(
      const Pipeline()
          .addMiddleware(logRequests()) // 日志中间件
          .addHandler(server.requestHandler), // 请求处理器
      host,
      port);
```

这是基于`shelf`框架启动http服务的代码，其中`addMiddleware(logRequests())`是给接口请求和反馈增加日志输出的中间件。  
我没有写过后端接口，看了下`Pipeline`的代码后觉得，正好可以使用中间件的方式来实现这个功能。  

## 实现

### 添加一个通用的拦截器中间件

新增拦截器中间件`interceptor_middleware.dart`：  

```Dart
Middleware interceptorMiddleware({Function beforeHandler, Function successHandler, Function errorHandler})
```

该中间件支持业务代码在每个请求处理前，处理成功后，处理失败后分别执行自己的逻辑。  

### 添加企业微信群机器人中间件

新增机器人中间件`qywx_robot_middleware.dart`：

```Dart
Middleware qywxRobotMiddleware(String qywxkey, {MsgBuilder msgBuilder})
```

该中间件封装了[interceptorMiddleware]，其中`qywxkey`是企业微信开放平台的key，`msgBuilder`是群机器人发送消息的消息体构造器，具体参看[群机器人配置说明](https://work.weixin.qq.com/api/doc/90000/90136/91770)的*消息类型及数据格式*。  

中间件的实现代码中拦截了`/api/packages/versions/newUpload`接口请求，当接口处理成功，且`statusCode`为302时，则调用相关API发送群机器人消息。  

本中间件提供了一个默认的消息体构造器：

```Dart
Map defaultMsgBuilder(PackageVersion packageVersion) {
  return {
    'msgtype': 'text',
    'text': {
      'content': 'OMG~我的天呐！Flutter Package ${packageVersion.packageName}的新品v${packageVersion.versionString}也太好看了吧！用它！用它！用它！',
      'mentioned_list': ['@all'],
    }
  };
}
```

### 可选择添加企业微信群机器人中间件

```Dart
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
```

在启动HTTP服务时，当`qywxkey`存在时，则加载机器人中间件，否则不加载。  
其中`qywxkey`通过命令行参数的形式传入：

```Dart
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
```

### 完整代码地址

[github](https://github.com/FantasyWind2016/pub_server)  

## 使用方法

```shell
cd ~/pub_server
dart example/example.dart -d ~/package-db -h 192.168.1.2 -p 8090 -q xxxx-xxxx-qywxkey
```

在启动服务时，在传入IP地址和接口外，额外传入`qywxkey`即可。  

最终效果：
![群机器人消息效果图](qywx_robot_result.png)

## 待优化细节

- `qywxRobotMiddleware`中间件代码中拦截的是`/api/packages/versions/newUpload`接口，该接口只是上传操作，并没有上传成功，所以理论上还是要拦截`/api/packages/versions/newUploadFinish`接口；
- `/api/packages/versions/newUpload`接口只返回了package的名称和版本号，没有该版本的修改内容；但是Package的官方指南中，更新说明是存在`CHANGELOG.md`文件中，所以想要读取版本更新说明，后面还需要解析MarkDown文件；
