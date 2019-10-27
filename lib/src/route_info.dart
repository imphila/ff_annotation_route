import 'package:ff_annotation_route/ff_annotation_route.dart';

class RouteInfo {
  final String className;
  final FFRoute ffRoute;
  RouteInfo({this.ffRoute, this.className});

  String get ctor {
    // var params = "";
    // if (ffRoute.argumentMapName != null && ffRoute.argumentMapName.isNotEmpty) {
    //   var key = ffRoute.argumentMapName;
    //   params = "$key: arguments";

    // }

    return "$className()";
  }

  String get caseString {
    return """    case ${ffRoute.name}:
      return RouteResult(widget: $ctor, ${ffRoute.showStatusBar != null ? 'showStatusBar: ${ffRoute.showStatusBar},' : ''} ${ffRoute.routeName != null ? 'routeName: ${ffRoute.routeName},' : ''} ${ffRoute.pageRouteType != null ? 'pageRouteType: ${ffRoute.pageRouteType},' : ''} ${ffRoute.description != null ? 'description: ${ffRoute.description},' : ''});\n""";
  }
}
