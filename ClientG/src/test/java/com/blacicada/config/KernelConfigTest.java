package com.blacicada.config;

import com.blacicada.common.ProxyConfig;
import com.blacicada.io.KernelDatabase;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;
import java.nio.file.*;
import java.util.*;
import static org.junit.jupiter.api.Assertions.*;

class KernelConfigTest {
    @TempDir Path directory;
    private KernelConfig.Profile profile(String id, String host, String protocol) {
        var values = new Properties();
        values.setProperty("server.host", host); values.setProperty("protocol", protocol);
        values.setProperty("password", "secret-test");
        return new KernelConfig.Profile(id, id, new ProxyConfig(values, directory));
    }
    @Test void endpointUniquenessNormalizesNamesAndIpv6ButSeparatesProtocols() {
        var local = new ProxyConfig(new Properties(), directory);
        assertThrows(IllegalArgumentException.class, () -> new KernelConfig(local,
                List.of(profile("a", "EXAMPLE.com.", "http2"), profile("b", "example.com", "http2")), "a"));
        assertThrows(IllegalArgumentException.class, () -> new KernelConfig(local,
                List.of(profile("a", "::1", "http3"), profile("b", "[0:0:0:0:0:0:0:1]", "http3")), "a"));
        assertEquals(2, new KernelConfig(local, List.of(profile("a", "example.com", "http2"), profile("b", "example.com", "http3")), "a").connections().size());
    }
    @Test void roundTripPreservesSecretsButPublicViewRedactsThem() throws Exception {
        var config = new KernelConfig(new ProxyConfig(new Properties(), directory), List.of(profile("a", "localhost", "http2")), "a");
        assertFalse(config.json(false).toString().contains("secret-test"));
        Path file = directory.resolve("kernel.db");
        try (var database = new KernelDatabase(file)) { database.stage(config, 0); database.commit(); }
        try (var database = new KernelDatabase(file)) {
            assertEquals("secret-test", database.read().configuration().profile("a").config().required("password"));
            assertEquals(1, database.read().revision());
        }
        if (file.getFileSystem().supportedFileAttributeViews().contains("posix"))
            assertEquals("rw-------", java.nio.file.attribute.PosixFilePermissions.toString(Files.getPosixFilePermissions(file)));
    }
    @Test void cannotDeleteDefaultAndInvalidUpdatesLeaveSnapshotUnchanged() {
        var config = new KernelConfig(new ProxyConfig(new Properties(), directory), List.of(profile("a", "localhost", "http2")), "a");
        assertThrows(IllegalArgumentException.class, () -> config.remove("a"));
        assertThrows(IllegalArgumentException.class, () -> config.select("absent"));
        assertEquals("a", config.defaultConnectionId());
    }

    @Test void rejectsOldFileAndServerFieldsInLocalConfiguration() throws Exception {
        Path old = directory.resolve("client.properties");
        Files.writeString(old, "server.host=localhost\npassword=test\n");
        assertThrows(java.io.IOException.class, () -> new KernelDatabase(old));
        Properties misplaced = new Properties(); misplaced.setProperty("server.host", "localhost");
        assertThrows(IllegalArgumentException.class, () -> new KernelConfig(new ProxyConfig(misplaced, directory),
                List.of(profile("a", "localhost", "http3")), "a"));
    }
}
