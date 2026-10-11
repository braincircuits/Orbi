package com.blacicada;

/** 代理内核只提供 Web 管理入口，转发由管理接口显式启动。 */
public class ClientApplication {
    public static void main(String[] args) throws Exception {
        if (args.length == 0 || !args[0].equals("--web"))
            throw new IllegalArgumentException("启动方式无效：请使用 --web [--db 数据库路径] 启动管理接口");
        com.blacicada.control.web.WebApplication.run(java.util.Arrays.copyOfRange(args, 1, args.length));
    }
}
