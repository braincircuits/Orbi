import com.blacicada.control.KernelControl;
import com.google.gson.Gson;

import java.nio.file.Files;

/**
 * 对真实内核的零版本号状态持续序列化，覆盖打包运行时的即时编译阶段。
 */
public class KernelJsonProbe {
    public static void main(String[] args) throws Exception {
        var directory = Files.createTempDirectory("network-json-probe-");
        try (var control = new KernelControl(directory.resolve("kernel.json"))) {
            var json = new Gson();
            for (int i = 0; i < 200_000; i++) {
                String response = json.toJson(control.status());
                if (response.indexOf('\0') >= 0 || !response.contains("\"revision\":0")) {
                    throw new AssertionError("内核数字序列化异常，循环次数：" + i);
                }
            }
            System.out.println("内核连续二十万次零版本号序列化通过");
        } finally {
            try (var files = Files.walk(directory)) {
                for (var file : files.sorted(java.util.Comparator.reverseOrder()).toList()) Files.delete(file);
            }
        }
    }
}
