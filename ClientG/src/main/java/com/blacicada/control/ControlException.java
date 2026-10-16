package com.blacicada.control;

/**
 * 可直接返回给代理客户端的稳定错误，不包含凭证或原始异常堆栈。
 */
public final class ControlException extends RuntimeException {
    public final int status;
    public final String code;
    public final String field;

    public ControlException(int status, String code, String message) {
        this(status, code, message, "");
    }

    public ControlException(int status, String code, String message, String field) {
        super(message);
        this.status = status;
        this.code = code;
        this.field = field;
    }
}
