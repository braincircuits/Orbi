import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:network_ui/services/kernel_api_client.dart';

void main() {
  test('损坏的 JSON 数字和非对象响应被拒绝，合法零版本号保持不变', () {
    expect(
      decodeKernelResponse('{"revision":0}', source: 'GET /status')['revision'],
      0,
    );
    for (final text in [
      '{"dirty":false,"revision":\u0000,"savedRevision":\u0000}',
      '[0]',
      'null',
    ]) {
      expect(
        () => decodeKernelResponse(text, source: 'SSE /events'),
        throwsA(
          isA<KernelApiException>()
              .having((e) => e.code, '错误代码', 'INVALID_RESPONSE')
              .having((e) => e.field, '响应来源', 'SSE /events'),
        ),
      );
    }
  });

  test('写入响应损坏时不重试，提示操作结果待核对且不暴露原始正文', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final client = KernelApiClient();
    var requests = 0;
    server.listen((request) async {
      requests++;
      await request.drain<void>();
      request.response.headers.contentType = ContentType.json;
      request.response.write('{"revision":\u0000,"password":"测试敏感内容"}');
      await request.response.close();
    });
    try {
      await expectLater(
        client.request(
          Uri.parse('http://127.0.0.1:${server.port}'),
          'test-only-token',
          'PUT',
          'config',
          body: <String, Object>{},
          expectedRevision: 0,
        ),
        throwsA(
          isA<KernelApiException>()
              .having((e) => e.code, '错误代码', 'INVALID_RESPONSE')
              .having((e) => e.message, '结果提示', contains('操作可能已生效'))
              .having((e) => e.toString(), '隐藏正文', isNot(contains('测试敏感内容'))),
        ),
      );
      expect(requests, 1);
    } finally {
      client.dispose();
      await server.close(force: true);
    }
  });
}
