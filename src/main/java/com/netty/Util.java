package com.netty;

public class Util {
    public static Host parseUrl(byte[] bytes) {
        String url = null;
        String port = null;
        int us = 0;
        int ue = 0;
        int ps = 0;
        int pe = 0;
        for (int i = 0; i < bytes.length; i++) {
            if (us == 0
                    && bytes[i] == 10
                    && bytes[i + 1] == 72
                    && bytes[i + 2] == 111
                    && bytes[i + 3] == 115
                    && bytes[i + 4] == 116
                    && bytes[i + 5] == 58
                    && bytes[i + 6] == 32
            ) {
                us = i + 7;
                i += 6;
            } else if (us != 0 && ps == 0 && bytes[i] == 13 && bytes[i + 1] == 10) {
                ue = i;
                ps = -1;
                port = "80";
                url = new String(bytes, us, ue - us);
                break;
            } else if (us != 0 && ps == 0 && bytes[i] == 58) {
                ue = i;
                ps = i + 1;
            } else if (ps > 0 && bytes[i] == 13 && bytes[i + 1] == 10) {
                pe = i;
                url = new String(bytes, us, ue - us);
                port = new String(bytes, ps, pe - ps);
                break;
            }

        }
        return new Host(url, Integer.parseInt(port));
    }
}
