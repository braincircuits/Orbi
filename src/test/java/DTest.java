import java.util.Map;
import java.util.concurrent.ConcurrentSkipListMap;

public class DTest
{
    public static void main(String[] args)
    {
        ConcurrentSkipListMap<Integer, String> map = new ConcurrentSkipListMap<>();
        map.put(4, "a");
        map.put(5, "a");
        map.put(6, "a");
        Map.Entry<Integer, String> integerStringEntry = map.pollFirstEntry();
        System.out.println(map);
    }
}
