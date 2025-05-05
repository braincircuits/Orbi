import org.apache.logging.log4j.LogManager;
import org.apache.logging.log4j.Logger;

import java.io.IOException;
import java.util.Properties;

public class Demo {
    private static Logger logger= LogManager.getLogger(Demo.class);
    public static void main(String[] args) throws IOException {
        Properties properties = new Properties();
        String[] strings = {"a", "b","c"};
        properties.put("abc", strings);


    }
}
