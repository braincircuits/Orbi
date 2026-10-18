#include <winsock2.h>
#include <ws2tcpip.h>
#include <jni.h>
#include <string>

// JNI 只访问 JDK 通道的描述符，不改变 Java 模块访问权限或代理协议。
extern "C" JNIEXPORT void JNICALL
Java_com_blacicada_common_WindowsSocketBinding_bind(JNIEnv* env, jclass, jobject channel, jint index, jboolean ipv6) {
    jclass type = env->GetObjectClass(channel);
    jfieldID descriptor = env->GetFieldID(type, "fd", "Ljava/io/FileDescriptor;");
    if (!descriptor) return;
    jobject fd = env->GetObjectField(channel, descriptor);
    jfieldID handle = env->GetFieldID(env->GetObjectClass(fd), "fd", "I");
    if (!handle) return;
    SOCKET socket = static_cast<SOCKET>(static_cast<unsigned int>(env->GetIntField(fd, handle)));
    DWORD value = ipv6 ? static_cast<DWORD>(index) : htonl(static_cast<DWORD>(index));
    if (setsockopt(socket, ipv6 ? IPPROTO_IPV6 : IPPROTO_IP,
                   ipv6 ? IPV6_UNICAST_IF : IP_UNICAST_IF,
                   reinterpret_cast<const char*>(&value), sizeof(value)) == SOCKET_ERROR) {
        std::string error = "Windows 出口接口绑定失败，错误码：" + std::to_string(WSAGetLastError());
        env->ThrowNew(env->FindClass("java/io/IOException"), error.c_str());
        return;
    }
    if (ipv6) {
        DWORD ipv4 = htonl(static_cast<DWORD>(index));
        if (setsockopt(socket, IPPROTO_IP, IP_UNICAST_IF, reinterpret_cast<const char*>(&ipv4), sizeof(ipv4)) == SOCKET_ERROR) {
            std::string error = "Windows IPv4 出口绑定失败，错误码：" + std::to_string(WSAGetLastError());
            env->ThrowNew(env->FindClass("java/io/IOException"), error.c_str());
        }
    }
}
