import 'package:shelf/shelf.dart';

Middleware interceptorMiddleware({Function beforeHandler, Function successHandler, Function errorHandler}) =>
    (innerHandler) {
      return (request) {
        if (beforeHandler!=null) {
          beforeHandler(request);
        }
        return Future.sync(() => innerHandler(request)).then((response) {
          if (successHandler!=null) {
            successHandler(request, response);
          }
          return response;
        }, onError: (error, StackTrace stackTrace) {
          if (errorHandler!=null) {
            errorHandler(request, error);
          }
          throw error;
        });
      };
    };