package com.blacicada.common;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Properties;
import static org.junit.jupiter.api.Assertions.*;

class ProxyCredentialsTest {
    @TempDir Path directory;

    private ProxyConfig config(String username, String password, boolean accounts) {
        var values = new Properties();
        if (username != null) values.setProperty("username", username);
        if (password != null) values.setProperty("password", password);
        if (accounts) values.setProperty("usersFile", "users.properties");
        return new ProxyConfig(values, directory);
    }

    @Test void accountsHaveIndependentPasswordsAndRejectLegacyToken() throws Exception {
        Files.writeString(directory.resolve("users.properties"), "alice=密码甲\nbob=密码乙:123\n");
        var server = ProxyCredentials.loadServer(config(null, "旧密码", true));
        assertEquals("alice", server.authenticate(ProxyCredentials.clientAuthorization(config("alice", "密码甲", false))));
        assertEquals("bob", server.authenticate(ProxyCredentials.clientAuthorization(config("bob", "密码乙:123", false))));
        assertNull(server.authenticate(ProxyCredentials.clientAuthorization(config("alice", "密码乙:123", false))));
        assertNull(server.authenticate(ProxyCredentials.clientAuthorization(config("unknown", "密码甲", false))));
        assertNull(server.authenticate(ProxyCredentials.clientAuthorization(config(null, "旧密码", false))));
        assertNull(server.authenticate("Basic 非法编码"));
        assertNull(server.authenticate(null));
        assertTrue(server.challenge().startsWith("Basic "));
    }

    @Test void sharedPasswordRemainsCompatible() throws Exception {
        var server = ProxyCredentials.loadServer(config(null, "兼容密码", false));
        assertNotNull(server.authenticate(ProxyCredentials.clientAuthorization(config(null, "兼容密码", false))));
        assertNull(server.authenticate(ProxyCredentials.clientAuthorization(config(null, "错误密码", false))));
        assertEquals("Bearer", server.challenge());
    }

    @Test void sharedPasswordRejectsMissingAndInvalidTokens() throws Exception {
        var configuration = config(null, "test-secret", false);
        var server = ProxyCredentials.loadServer(configuration);
        String token = ProxyCredentials.clientAuthorization(configuration);
        assertEquals("Bearer dGVzdC1zZWNyZXQ=", token);
        assertEquals("共享密码", server.authenticate(token));
        assertNull(server.authenticate(null));
        assertNull(server.authenticate("Bearer wrong"));
        assertNull(server.authenticate(ProxyCredentials.clientAuthorization(config("alice", "test-secret", false))));
    }

    @Test void invalidAccountFilesFailClosed() throws Exception {
        assertThrows(java.io.IOException.class, () -> ProxyCredentials.loadServer(config(null, "旧密码", true)));
        for (String text : new String[]{"", "alice=\n", "alice=a\nalice=b\n", "bad\\:name=password\n"}) {
            Files.writeString(directory.resolve("users.properties"), text);
            assertThrows(IllegalArgumentException.class, () -> ProxyCredentials.loadServer(config(null, "旧密码", true)));
        }
    }

    @Test void removingAccountTakesEffectAfterReload() throws Exception {
        Files.writeString(directory.resolve("users.properties"), "alice=a\nbob=b\n");
        String alice = ProxyCredentials.clientAuthorization(config("alice", "a", false));
        assertNotNull(ProxyCredentials.loadServer(config(null, null, true)).authenticate(alice));
        Files.writeString(directory.resolve("users.properties"), "bob=b\n");
        assertNull(ProxyCredentials.loadServer(config(null, null, true)).authenticate(alice));
    }
}
