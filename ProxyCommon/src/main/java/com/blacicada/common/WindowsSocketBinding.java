package com.blacicada.common;

import java.io.*;
import java.nio.channels.SelectableChannel;
import java.nio.file.*;

/** Windows 使用 IP_UNICAST_IF 约束真实出口，避免出站流量再次进入 TUN。 */
final class WindowsSocketBinding {
    static {
        try (var input = WindowsSocketBinding.class.getResourceAsStream("/native/windows-x86_64/orbi-network.dll")) {
            if (input == null) throw new IOException("缺少 Windows 出口绑定库，请在 Windows 上重新构建");
            Path directory = Files.createTempDirectory("orbi-network-");
            Path library = directory.resolve("orbi-network.dll");
            directory.toFile().deleteOnExit();
            library.toFile().deleteOnExit();
            Files.copy(input, library);
            System.load(library.toString());
        } catch (IOException failure) {
            throw new ExceptionInInitializerError(failure);
        }
    }

    static native void bind(SelectableChannel channel, int index, boolean ipv6) throws IOException;
}
