package com.blacicada.common.util.key;

import java.io.FileInputStream;
import java.io.IOException;

public class KeyUtil {
    public static byte[] byteMap =loadKey();

    private static byte[] loadKey()  {
        try(FileInputStream key = new FileInputStream("key");) {
            return key.readAllBytes();
        } catch (IOException e) {
            throw new RuntimeException("key文件不存在");
        }
    }
}
