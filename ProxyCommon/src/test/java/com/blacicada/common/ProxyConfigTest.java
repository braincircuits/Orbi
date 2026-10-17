package com.blacicada.common;

import org.junit.jupiter.api.Test;

import java.io.PrintWriter;
import java.io.StringWriter;
import java.nio.file.Path;
import java.util.Properties;

import static org.junit.jupiter.api.Assertions.*;

class ProxyConfigTest {
    @Test
    void invalidNumbersDoNotEchoValuesInExceptionsOrCauses() {
        for (String value : new String[]{"password-secret", "Bearer token-secret", "999999999999999999999999"}) {
            var values = new Properties();
            values.setProperty("maxStreams", value);
            var config = new ProxyConfig(values, Path.of("."));
            var failure = assertThrows(IllegalArgumentException.class, config::maxStreams);
            var stack = new StringWriter();
            failure.printStackTrace(new PrintWriter(stack));
            assertTrue(failure.getMessage().contains("maxStreams"));
            assertFalse(stack.toString().contains(value));
        }
    }
}
