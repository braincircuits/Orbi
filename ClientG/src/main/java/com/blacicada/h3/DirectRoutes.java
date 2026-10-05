package com.blacicada.h3;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Locale;
import java.util.Set;
import java.util.stream.Collectors;

/** pac.txt remains a list of domains that bypass the remote proxy. */
public final class DirectRoutes {
    private final Set<String> domains;
    public DirectRoutes(Path file) throws IOException {
        if (!Files.exists(file)) { domains = Set.of(); return; }
        try (var lines = Files.lines(file)) {
            domains = lines.map(String::trim).filter(s -> !s.isEmpty() && !s.startsWith("#"))
                    .map(s -> s.toLowerCase(Locale.ROOT)).collect(Collectors.toUnmodifiableSet());
        }
    }
    public boolean matches(String host) {
        String name = host.toLowerCase(Locale.ROOT);
        if (name.endsWith(".")) name = name.substring(0, name.length() - 1);
        while (true) {
            if (domains.contains(name)) return true;
            int dot = name.indexOf('.');
            if (dot < 0) return false;
            name = name.substring(dot + 1);
        }
    }
}
