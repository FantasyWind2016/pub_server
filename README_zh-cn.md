# 已归档

本仓库已经被归档，不再维护。

我们也不再回复所有的Issue和PR。

如果社区对于Dart的代理包服务器有感兴趣，我们建议将其作为社区项目进行维护。

**提示：当前软件包只是alpha测试版本，不建议在生产中使用。**  

本代码仓库提供了可重复使用的代码，用来搭建Dart包存储库服务器。

`package:pub_server/shelf_pubserver.dart`实现了一个[shelf]框架的HTTP处理器，响应pub客户端发出的HTTP接口请求。

你可以实现`package:pub_server/repository.dart`文件中的`PackageRepository`接口，用来自定义一个不同的后端服务器。

## Example pub repository server

## Pub存储库服务器示例

`example/example.dart`提供了一个基于文件系统的实验性Pub服务器。它使用了基于文件系统的`PackageRepository`来存储packages，并且当前package包在文件系统中不存在时，将直接读取`pub.flutter-io.cn`网站作为应变方案。这样用户就可以使用`pub.flutter-io.cn`上面的所有包，并且在这些公共可用包的基础上，还可以使用额外新增的包，当然这些包只能在本地使用。

你可以像下面这样运行：

```bash
~ $ git clone https://github.com/dart-lang/pub_server.git
~ $ cd pub_server
~/pub_server $ pub get
...
~/pub_server $ dart example/example.dart -d /tmp/package-db
Listening on http://localhost:8080

To make the pub client use this repository configure your shell via:
    $ export PUB_HOSTED_URL=http://localhost:8080
```

使用它将新包上传到本地运行的服务器，或下载本地服务器可用的包，或通过回退到`pub.flutter-io.cn`获取包，操作非常简单：

```bash
~/foobar $ export PUB_HOSTED_URL=http://localhost:8080
~/foobar $ pub get
...
~/foobar $ pub publish
Publishing x 0.1.0 to http://localhost:8080:
|-- ...
'-- pubspec.yaml

Looks great! Are you ready to upload your package (y/n)? y
Uploading...
Successfully uploaded package.
```

因为`pub publish`在没有身份验证或其他身份验证方案的情况下无法工作，`pub publish`命令要求您授予它oauth2访问权限（这需要一个Google帐户）。

*但是目前此本地服务器还没有使用pub客户端发送的信息。*

[shelf]: https://pub.dartlang.org/packages/shelf
