import com.blacicada.control.KernelControl;
import org.apache.logging.log4j.LogManager;
import org.apache.logging.log4j.core.Logger;
import java.nio.file.Path;
import java.util.List;
import java.util.Map;
import java.util.Set;

/** 在打包运行时验证按类创建的业务日志可被管理接口读取和推送。 */
public class KernelLogsProbe {
    private static final Logger LOGGER = (Logger) LogManager.getLogger(KernelLogsProbe.class);

    public static void main(String[] args) throws Exception {
        String appenderName;
        try (var control = new KernelControl(Path.of("kernel.json"))) {
            appenderName = control.logs().getName();
            if (LOGGER.getContext().getRootLogger().getAppenders().get(appenderName) != control.logs()) {
                throw new AssertionError("管理日志采集器未注册到业务日志上下文");
            }
            long cursor = control.events().cursor();
            LOGGER.info("管理日志回归：启动信息");
            LOGGER.warn("管理日志回归：连接警告");
            long deadline = System.nanoTime() + 5_000_000_000L;
            List<?> items;
            do {
                items = (List<?>) control.logs().read(0, 500, Set.of()).get("items");
                if (items.size() >= 2) break;
                Thread.sleep(10);
            } while (System.nanoTime() < deadline);
            for (String level : List.of("INFO", "WARN")) {
                if (items.stream().noneMatch(item -> item instanceof Map<?, ?> entry
                        && level.equals(entry.get("level"))
                        && KernelLogsProbe.class.getName().equals(entry.get("logger")))) {
                    throw new AssertionError("管理日志缺少业务记录：" + level);
                }
            }
            var pushed = control.events().await(cursor, 0).events().stream()
                    .filter(event -> event.type().equals("log")).map(event -> event.data()).toList();
            if (!pushed.containsAll(items)) {
                throw new AssertionError("日志事件未推送全部已采集记录");
            }
        }
        if (LOGGER.getContext().getRootLogger().getAppenders().containsKey(appenderName)) {
            throw new AssertionError("内核关闭后未移除管理日志采集器");
        }
        System.out.println("打包运行时业务日志读取、事件推送与采集器释放验证通过");
    }
}
