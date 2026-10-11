import 'dart:async';
import 'dart:convert';
import 'dart:io';

class KernelApiException implements Exception {
  KernelApiException(
    this.code,
    this.message, {
    this.field = '',
    this.statusCode,
  });
  final String code, message, field;
  final int? statusCode;
  @override
  String toString() => '$message（$code${field.isEmpty ? '' : ' · $field'}）';
}

/// 严格解析管理响应；错误提示不携带可能包含敏感信息的原始正文。
Map<String, dynamic> decodeKernelResponse(
  String text, {
  required String source,
}) {
  try {
    final value = jsonDecode(text);
    if (value is Map<String, dynamic>) return value;
  } on FormatException {
    // 不修补损坏的数值，避免把错误版本号用于后续配置写入。
  }
  throw KernelApiException(
    'INVALID_RESPONSE',
    '内核响应格式异常，请重新读取核对；若持续出现，请退出代理内核后重新启动。'
        '操作可能已生效，请勿重复提交',
    field: source,
  );
}

/// 管理 HTTP 请求、认证、超时和错误解析，不持有界面状态。
class KernelApiClient {
  final HttpClient _http = HttpClient()..findProxy = (_) => 'DIRECT';
  Future<Map<String, dynamic>> request(
    Uri base,
    String token,
    String method,
    String path, {
    Object? body,
    int? expectedRevision,
  }) async {
    HttpClientRequest? request;
    try {
      request = await _http
          .openUrl(method, base.resolve('/api/v1/$path'))
          .timeout(const Duration(seconds: 5));
      request.followRedirects = false;
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      request.headers.contentType = ContentType.json;
      if (expectedRevision != null) {
        request.headers.set(HttpHeaders.ifMatchHeader, '"$expectedRevision"');
      }
      if (body != null) request.write(jsonEncode(body));
      final response = await request.close().timeout(
        const Duration(seconds: 25),
      );
      final text = await utf8.decoder
          .bind(response)
          .join()
          .timeout(const Duration(seconds: 25));
      final result = decodeKernelResponse(text, source: '$method /$path');
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final failure = result['error'] as Map<String, dynamic>? ?? {};
        final code = '${failure['code'] ?? 'HTTP_${response.statusCode}'}';
        throw KernelApiException(
          code,
          '${failure['message'] ?? '内核请求失败'}',
          field: '${failure['field'] ?? ''}',
          statusCode: response.statusCode,
        );
      }
      return result;
    } on TimeoutException {
      request?.abort();
      throw StateError('内核响应超时，操作结果可能已生效；请重新读取后核对，客户端不会自动重试写入');
    }
  }

  void dispose() => _http.close(force: true);
}
