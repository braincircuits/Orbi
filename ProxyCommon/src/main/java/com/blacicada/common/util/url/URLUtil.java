package com.blacicada.common.util.url;

import io.netty.buffer.ByteBuf;
import org.apache.logging.log4j.LogManager;
import org.apache.logging.log4j.Logger;

public class URLUtil {
    private static final Logger logger = LogManager.getLogger(URLUtil.class);

    // 解析Connect 报文
    public static Host parseUrl(byte[] bytes) {
        String url = null;
        String port = null;
        boolean https = true;
        int us = 0;
        int ue = 0;
        int ps = 0;
        int pe = 0;
        if (bytes[0] != 67) {//判断第一个字节是否是 大写的C
            https = false;
        }
        for (int i = 0; i < bytes.length; i++) {
            if (us == 0) {
                if (https && bytes[i] == 58 && bytes[i + 1] != 32 && bytes[i + 1] != 47) {
                    ps = i + 1;
                }
                if (https && ps != 0 && bytes[i] == 32 && pe == 0) {
                    pe = i;
                }
                //上面两个if 从 CONNECT www.baidu.com:443 HTTP/1.1 中获取端口

                if (
                        bytes[i] == 10    //判断是不是换行符'/n' 换行符 由两个字符组成 13 10
                                && (bytes[i + 1] == 72 || bytes[i + 1] == 104)//判断是不是大写的H或小写的h
                                && bytes[i + 2] == 111//判断是不是小写的o
                                && bytes[i + 3] == 115//判断是不是小写的s
                                && bytes[i + 4] == 116//判断是不是小写的t
                                && bytes[i + 5] == 58//判断是不是:
                                && bytes[i + 6] == 32//判断是不是空格' '
                ) {
                    us = i + 7;
                    i += 6;
                }
            } else if (pe == 0) {
                if (ue != 0 && bytes[i] == 13 && bytes[i + 1] == 10) {
                    pe = i;
                    url = new String(bytes, us, ue - us);
                    port = new String(bytes, ps, pe - ps);
                    break;
                }
                if (bytes[i] == 13// 判断是不是到了换行符了
                        && bytes[i + 1] == 10) {
                    ue = i;
                    port = "80";
                    url = new String(bytes, us, ue - us);
                    break;
                }

                if (bytes[i] == 58) {
                    ue = i;
                    ps = i + 1;
                }

            } else {
                if (bytes[i] == 58 || bytes[i] == 13 && bytes[i + 1] == 10) {
                    ue = i;
                    url = new String(bytes, us, ue - us);
                    port = new String(bytes, ps, pe - ps);
                    break;
                }
            }

        }
        return new Host(url, Integer.parseInt(port), https);
    }

    public static Host parseUrl(ByteBuf byteBuf) {
        byte[] bytes = new byte[byteBuf.readableBytes()];
        byteBuf.getBytes(0, bytes);
        try {
            return parseUrl(bytes);
        } catch (Exception e) {
            logger.error("connect 报文解析错误 ==========={}", new String(bytes));
            throw e;
        }
    }
}
