package com.blacicada;

import com.blacicada.A.CException;

public class Demo {
    volatile static Integer a=1;
    private static String github=
            """
            CONNECT github.com:443 HTTP/1.1
            Host: github.com:443
            Proxy-Connection: keep-alive""";
    public static void main(String[] args) throws CException {

        String aTrue = System.setProperty("java.net.useSystemProxies", "true");
        System.out.println(aTrue);
    }

    public static void show()  {

    }

    public static Integer getA() {
        return a;
    }
}
