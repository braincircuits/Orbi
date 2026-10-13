#!/usr/bin/env python3
"""验证 AOT MySQL 驱动的加载和认证握手，不替代真实数据库的建表及读写测试。"""
import os
import pathlib
import socket
import struct
import subprocess
import tempfile
import threading


def main():
    root = pathlib.Path(__file__).resolve().parents[1]
    state = []
    with socket.socket() as server:
        server.bind(('127.0.0.1', 0))
        server.listen()
        server.settimeout(8)

        def serve():
            try:
                connection, _ = server.accept()
                with connection:
                    connection.settimeout(5)
                    # 声明协议 4.1、安全认证响应及 caching_sha2_password；不接受真实凭据。
                    capabilities = 1 | 512 | 8192 | 32768 | (1 << 19) | (1 << 21)
                    payload = (b'\x0a8.4.0-test\0' + struct.pack('<I', 1) + b'12345678\0'
                               + struct.pack('<H', capabilities & 65535) + b'\x21'
                               + struct.pack('<H', 2) + struct.pack('<H', capabilities >> 16)
                               + b'\x15' + b'\0' * 10 + b'abcdefghijkL\0' + b'caching_sha2_password\0')
                    connection.sendall(len(payload).to_bytes(3, 'little') + b'\x00' + payload)
                    state.append(bool(connection.recv(65536)))
                    error = b'\xff' + struct.pack('<H', 1045) + b'#28000' + '测试端点拒绝认证'.encode()
                    connection.sendall(len(error).to_bytes(3, 'little') + b'\x02' + error)
            except Exception as error:
                state.append(type(error).__name__)

        thread = threading.Thread(target=serve, daemon=True)
        thread.start()
        with tempfile.TemporaryDirectory(prefix='network-mysql-probe-') as directory:
            config = pathlib.Path(directory) / 'storage.properties'
            config.write_text(f'type=mysql\nhost=127.0.0.1\nport={server.getsockname()[1]}\n'
                              'database=test\nusername=test\npassword=test\nsslMode=disable\n')
            command = os.environ.get('NATIVE_CORE', str(root / 'ClientG/target/native/network-core'))
            result = subprocess.run([command, '--web', '--storage-config', str(config), '--port', '0'],
                                    capture_output=True, timeout=15)
            thread.join(9)
            output = (result.stdout + result.stderr).decode(errors='replace')
            assert state == [True], 'MySQL 原生驱动未发送认证请求：' + output
            assert result.returncode != 0, '测试端点拒绝认证后内核不应启动'
            assert 'ExceptionInInitializerError' not in output and 'MissingReflectionRegistrationError' not in output, \
                '数据库驱动原生元数据不完整：' + output
            print('MySQL 原生驱动加载、协议握手及认证失败处理通过；尚未验证真实 MySQL 数据库')


if __name__ == '__main__':
    main()
