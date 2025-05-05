import org.junit.jupiter.api.Test;

import java.io.FileInputStream;
import java.io.IOException;

public class CommonTest {
    @Test
    public void urlA() {
        FileInputStream key = null;
        try {
            key = new FileInputStream("C:\\O\\idea\\IdeaProjects\\study\\network\\key");
            byte[] byteKey = key.readAllBytes();
            System.out.println("=======");
        } catch (IOException e) {
            throw new RuntimeException(e);
        }
    }
}
