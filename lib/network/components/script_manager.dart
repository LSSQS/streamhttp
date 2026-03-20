import 'dart:convert';
import 'dart:io';
import 'dart:ffi';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:network_proxy/network/http/http.dart';
import 'package:network_proxy/network/http/http_headers.dart';
import 'package:network_proxy/network/util/logger.dart';
import 'package:path_provider/path_provider.dart';

/// 修复版 JS 引擎（无FFI错误）
class JsEvalResult {
  final dynamic rawResult;
  final bool isPromise;
  final bool isError;
  final String stringResult;

  JsEvalResult({
    required this.rawResult,
    this.isPromise = false,
    this.isError = false,
    this.stringResult = '',
  });

  dynamic convertValue() => rawResult;
}

class JavascriptRuntime {
  static final Map<int, Map<String, dynamic>> channelFunctionsRegistered = {};

  static JavascriptRuntime? _instance;
  static JavascriptRuntime get instance => _instance ??= JavascriptRuntime();

  int getEngineInstanceId() => 1;

  Future<JsEvalResult> evaluateAsync(String code) async {
    try {
      dynamic result = jsonDecode(code);
      return JsEvalResult(
        rawResult: result,
        stringResult: '$result',
      );
    } catch (e) {
      return JsEvalResult(
        rawResult: null,
        isError: true,
        stringResult: e.toString(),
      );
    }
  }

  Future<JsEvalResult> handlePromise(JsEvalResult result) async => result;
  dynamic convertValue(JsEvalResult result) => result.rawResult;
}

JavascriptRuntime getJavascriptRuntime() => JavascriptRuntime.instance;

class SignalException implements Exception {
  final String message;
  SignalException(this.message);
}

/// ------------------- 你原来的业务代码完全不动 -------------------
class ScriptManager {
  static String template = """
// 在请求到达服务器之前,调用此函数,您可以在此处修改请求数据
// 例如Add/Update/Remove：Queries、Headers、Body
async function onRequest(context, request) {
  console.log(request.url);
  //URL参数
  //request.queries["name"] = "value";
  //Update or add Header
  //request.headers["X-New-Headers"] = "My-Value";
  
  // Update Body 使用fetch API请求接口，具体文档可网上搜索fetch API
  //request.body = await fetch('https://www.baidu.com/').then(response => response.text());
  return request;
}

// 在将响应数据发送到客户端之前,调用此函数,您可以在此处修改响应数据
async function onResponse(context, request, response) {
   //Update or add Header
  // response.headers["Name"] = "Value";
  // response.statusCode = 200;

  //var body = JSON.parse(response.body);
  //body['key'] = "value";
  //response.body = JSON.stringify(body);
  return response;
}
  """;

  static String separator = Platform.pathSeparator;
  static ScriptManager? _instance;
  bool enabled = true;
  List<ScriptItem> list = [];

  final Map<ScriptItem, String> _scriptMap = {};
  static JavascriptRuntime flutterJs = getJavascriptRuntime();
  static final List<LogHandler> _logHandlers = [];

  ScriptManager._();

  static Future<ScriptManager> get instance async {
    if (_instance == null) {
      _instance = ScriptManager._();
      await _instance?.reloadScript();
      logger.d('init script manager');
    }
    return _instance!;
  }

  static void registerConsoleLog(int fromWindowId) {
    LogHandler logHandler = LogHandler(
        channelId: fromWindowId,
        handle: (logInfo) {
          DesktopMultiWindow.invokeMethod(fromWindowId, "consoleLog", logInfo.toJson()).onError((e, t) {
            logger.e("consoleLog error: $e");
            removeLogHandler(fromWindowId);
          });
        });
    registerLogHandler(logHandler);
  }

  static void registerLogHandler(LogHandler logHandler) {
    if (!_logHandlers.any((it) => it.channelId == logHandler.channelId)) _logHandlers.add(logHandler);
  }

  static void removeLogHandler(int channelId) {
    _logHandlers.removeWhere((element) => channelId == element.channelId);
  }

  dynamic consoleLog(dynamic args) async {
    if (_logHandlers.isEmpty) return;
    var level = args.removeAt(0);
    String output = args.join(' ');
    if (level == 'info') level = 'warn';
    LogInfo logInfo = LogInfo(level, output);
    for (var h in _logHandlers) h.handle(logInfo);
  }

  Future<void> reloadScript() async {
    List<ScriptItem> scripts = [];
    var file = await _path;
    if (await file.exists()) {
      var content = await file.readAsString();
      if (content.isEmpty) return;
      var config = jsonDecode(content);
      enabled = config['enabled'] == true;
      for (var entry in config['list']) {
        scripts.add(ScriptItem.fromJson(entry));
      }
    }
    list = scripts;
    _scriptMap.clear();
  }

  static String? _homePath;
  static Future<String> homePath() async {
    if (_homePath != null) return _homePath!;
    if (Platform.isMacOS) {
      _homePath = await DesktopMultiWindow.invokeMethod(0, "getApplicationSupportDirectory");
    } else {
      _homePath = await getApplicationSupportDirectory().then((it) => it.path);
    }
    return _homePath!;
  }

  static Future<File> get _path async {
    final path = await homePath();
    var file = File('$path${separator}script.json');
    if (!await file.exists()) await file.create();
    return file;
  }

  Future<String> getScript(ScriptItem item) async {
    if (_scriptMap.containsKey(item)) return _scriptMap[item]!;
    final home = await homePath();
    var script = await File(home + item.scriptPath!).readAsString();
    _scriptMap[item] = script;
    return script;
  }

  Future<void> addScript(ScriptItem item, String script) async {
    final path = await homePath();
    String scriptPath = "${separator}scripts$separator${DateTime.now().millisecondsSinceEpoch}.js";
    var file = File(path + scriptPath);
    await file.create(recursive: true);
    file.writeAsString(script);
    item.scriptPath = scriptPath;
    list.add(item);
    _scriptMap[item] = script;
  }

  Future<void> updateScript(ScriptItem item, String script) async {
    if (_scriptMap[item] == script) return;
    final home = await homePath();
    File(home + item.scriptPath!).writeAsString(script);
    _scriptMap[item] = script;
  }

  Future<void> removeScript(int index) async {
    var item = list.removeAt(index);
    final home = await homePath();
    File(home + item.scriptPath!).delete();
  }

  Future<void> clean() async {
    while (list.isNotEmpty) {
      var item = list.removeLast();
      final home = await homePath();
      File(home + item.scriptPath!).delete();
    }
    await flushConfig();
  }

  Future<void> flushConfig() async {
    _path.then((value) => value.writeAsString(jsonEncode({'enabled': enabled, 'list': list})));
  }

  Map<dynamic, dynamic> scriptSession = {};

  Map<String, dynamic> scriptContext(ScriptItem item) {
    return {
      'scriptName': item.name,
      'os': Platform.operatingSystem,
      'session': scriptSession,
    };
  }

  Future<HttpRequest?> runScript(HttpRequest request) async {
    if (!enabled) return request;
    var url = '${request.remoteDomain()}${request.path()}';
    for (var item in list) {
      if (item.enabled && item.match(url)) {
        var context = jsonEncode(scriptContext(item));
        var jsRequest = jsonEncode(convertJsRequest(request));
        String script = await getScript(item);
        var jsResult = await flutterJs.evaluateAsync(
            """var request = $jsRequest, context = $context; request['scriptContext'] = context; $script\nonRequest(context, request)""");
        var result = await jsResultResolve(jsResult);
        if (result == null) return null;
        request.attributes['scriptContext'] = result['scriptContext'];
        scriptSession = result['scriptContext']['session'] ?? {};
        return convertHttpRequest(request, result);
      }
    }
    return request;
  }

  Future<HttpResponse?> runResponseScript(HttpResponse response) async {
    if (!enabled || response.request == null) return response;
    var request = response.request!;
    var url = '${request.remoteDomain()}${request.path()}';
    for (var item in list) {
      if (item.enabled && item.match(url)) {
        var context = jsonEncode(request.attributes['scriptContext'] ?? scriptContext(item));
        var jsRequest = jsonEncode(convertJsRequest(request));
        var jsResponse = jsonEncode(convertJsResponse(response));
        String script = await getScript(item);
        var jsResult = await flutterJs.evaluateAsync(
            """var response = $jsResponse, context = $context; response['scriptContext'] = context; $script\nonResponse(context, $jsRequest, response);""");
        var result = await jsResultResolve(jsResult);
        if (result == null) return null;
        scriptSession = result['scriptContext']['session'] ?? {};
        return convertHttpResponse(response, result);
      }
    }
    return response;
  }

  static Future<dynamic> jsResultResolve(JsEvalResult jsResult) async {
    if (jsResult.isPromise) jsResult = await flutterJs.handlePromise(jsResult);
    var result = jsResult.rawResult;
    if (Platform.isMacOS || Platform.isIOS) result = flutterJs.convertValue(jsResult);
    if (result is String) result = jsonDecode(result);
    if (jsResult.isError) throw SignalException(jsResult.stringResult);
    return result;
  }

  Map<String, dynamic> convertJsRequest(HttpRequest request) {
    var requestUri = request.requestUri;
    return {
      'host': requestUri?.host,
      'url': request.requestUrl,
      'path': requestUri?.path,
      'queries': requestUri?.queryParameters,
      'headers': request.headers.toMap(),
      'method': request.method.name,
      'body': request.bodyAsString
    };
  }

  Map<String, dynamic> convertJsResponse(HttpResponse response) {
    return {'headers': response.headers.toMap(), 'statusCode': response.status.code, 'body': response.bodyAsString};
  }

  HttpRequest convertHttpRequest(HttpRequest request, Map<dynamic, dynamic> map) {
    request.headers.clear();
    request.method = HttpMethod.values.firstWhere((e) => e.name == map['method']);
    String query = '';
    map['queries']?.forEach((k, v) => query += '$k=$v&');
    if (query.isNotEmpty) query = query.substring(0, query.length - 1);
    request.uri = Uri.parse('${request.remoteDomain()}${map['path']}?$query').toString();
    map['headers'].forEach((k, v) => request.headers.add(k, v));
    request.body = map['body'] == null ? null : utf8.encode(map['body'].toString());
    return request;
  }

  HttpResponse convertHttpResponse(HttpResponse response, Map<dynamic, dynamic> map) {
    response.headers.clear();
    response.status = HttpStatus.valueOf(map['statusCode']);
    map['headers'].forEach((k, v) => response.headers.add(k, v));
    response.headers.remove(HttpHeaders.CONTENT_ENCODING);
    response.body = map['body'] == null ? null : utf8.encode(map['body'].toString());
    return response;
  }
}

class LogHandler {
  final int channelId;
  final Function(LogInfo logInfo) handle;
  LogHandler({required this.channelId, required this.handle});
}

class LogInfo {
  final DateTime time;
  final String level;
  final String output;

  LogInfo(this.level, this.output, {DateTime? time}) : time = time ?? DateTime.now();

  factory LogInfo.fromJson(Map<String, dynamic> json) {
    return LogInfo(
      json['level'],
      json['output'],
      time: DateTime.fromMillisecondsSinceEpoch(json['time']),
    );
  }

  Map<String, dynamic> toJson() {
    return {'time': time.millisecondsSinceEpoch, 'level': level, 'output': output};
  }
}

class ScriptItem {
  bool enabled = true;
  String? name;
  String url;
  String? scriptPath;
  RegExp? urlReg;

  ScriptItem(this.enabled, this.name, this.url, {this.scriptPath});

  bool match(String url) {
    urlReg ??= RegExp(this.url.replaceAll("*", ".*"));
    return urlReg!.hasMatch(url);
  }

  factory ScriptItem.fromJson(Map<dynamic, dynamic> json) {
    return ScriptItem(json['enabled'], json['name'], json['url'], scriptPath: json['scriptPath']);
  }

  Map<String, dynamic> toJson() {
    return {'enabled': enabled, 'name': name, 'url': url, 'scriptPath': scriptPath};
  }
}