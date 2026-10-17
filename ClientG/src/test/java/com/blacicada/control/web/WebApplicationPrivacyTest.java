package com.blacicada.control.web;

import org.junit.jupiter.api.Test;

import java.io.PrintWriter;
import java.io.StringWriter;

import static org.junit.jupiter.api.Assertions.*;

class WebApplicationPrivacyTest {
    @Test
    void invalidStartupArgumentsDoNotEchoSecretsOrRawParserCauses() {
        String secret = "unregistered-credential-secret";
        for (String[] args : new String[][]{
                {"--port", secret},
                {"--allow-origin", "http://user:" + secret + "@[invalid"},
                {"--db", "invalid\0" + secret},
                {"--token=" + secret, "unused"},
                {"--token=" + secret}
        }) {
            var failure = assertThrows(IllegalArgumentException.class, () -> WebApplication.run(args));
            var stack = new StringWriter();
            failure.printStackTrace(new PrintWriter(stack));
            assertTrue(failure.getMessage().contains("启动参数"));
            assertFalse(stack.toString().contains(secret));
        }
    }
}
