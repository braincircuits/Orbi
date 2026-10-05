import com.blacicada.common.h3.Authority;
import com.blacicada.common.h3.Transport;
import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

class CommonTest {
    @Test void parsesAuthoritiesWithoutDns() {
        assertEquals(new Authority("example.com", 443), Authority.parse("EXAMPLE.com:443", -1));
        assertEquals("[::1]:8080", Authority.parse("[::1]:8080", -1).toString());
        assertEquals(80, Authority.parse("localhost", 80).port());
        assertTrue(Authority.parse("example.invalid:80", -1).unresolved().isUnresolved());
        for (String invalid : new String[]{"host", "host:0", "host:65536", "host:-1", "host:+80", "[::1]x:80", "user@host:80", "a/b:80", "::1:80"}) {
            assertThrows(IllegalArgumentException.class, () -> Authority.parse(invalid, -1), invalid);
        }
    }
    @Test void authenticatesWithoutExposingPasswordInHeaders() {
        String token = Transport.authorization("test-secret");
        assertTrue(Transport.authorized(token, token));
        assertFalse(Transport.authorized(token, null));
        assertFalse(Transport.authorized(token, "Bearer wrong"));
    }
}
