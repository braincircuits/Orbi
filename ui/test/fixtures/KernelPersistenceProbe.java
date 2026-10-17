import java.nio.file.Files;
import java.nio.file.Path;
import java.sql.DriverManager;

/**
 * 查询内核运行时的真实 SQLite 数据，验证密码已持久化，不获取内核实例锁。
 */
public class KernelPersistenceProbe {
    public static void main(String[] args) throws Exception {
        if (args.length != 2 || !Files.isRegularFile(Path.of(args[0]))) {
            throw new IllegalArgumentException("需要现有数据库文件路径和预期密码");
        }
        try (var connection = DriverManager.getConnection("jdbc:sqlite:" + args[0]);
             var statement = connection.createStatement()) {
            statement.execute("PRAGMA busy_timeout=3000");
            statement.execute("PRAGMA query_only=ON");
            try (var rows = statement.executeQuery("SELECT value FROM profile_settings WHERE key='password'")) {
                if (!rows.next() || !args[1].equals(rows.getString(1))) {
                    throw new AssertionError("数据库未保存预期的代理密码");
                }
                if (rows.next()) throw new AssertionError("数据库中的代理密码记录应恰好一条");
            }
        }
        System.out.println("真实数据库代理密码持久化验证通过");
    }
}
