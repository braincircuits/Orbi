package com.blacicada.io;

import java.io.IOException;
import java.nio.file.*;
import java.nio.file.attribute.PosixFilePermissions;

/** 配置和管理令牌文件共用的私有原子写入；父目录由调用方准备。 */
public final class PrivateFiles {
    private PrivateFiles() { }
    public static void writeAtomic(Path file, String contents) throws IOException {
        Path absolute = file.toAbsolutePath();
        Path temporary = Files.createTempFile(absolute.getParent(), ".network-", ".json");
        try {
            if (Files.getFileStore(temporary).supportsFileAttributeView("posix"))
                Files.setPosixFilePermissions(temporary, PosixFilePermissions.fromString("rw-------"));
            Files.writeString(temporary, contents);
            Files.move(temporary, absolute, StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING);
        } finally { Files.deleteIfExists(temporary); }
    }
}
