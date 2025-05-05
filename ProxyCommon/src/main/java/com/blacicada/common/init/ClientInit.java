package com.blacicada.common.init;

import org.apache.commons.io.IOUtils;
import org.apache.commons.lang3.StringUtils;

import java.io.FileInputStream;
import java.io.IOException;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.util.HashSet;
import java.util.List;
import java.util.Properties;
import java.util.stream.Stream;

public class ClientInit
{
    public final static HashSet<Integer> urls = urlHash();
    public static final Properties properties = loadProperties();
    public static final byte[] password = ((String) properties.get("password")).getBytes(StandardCharsets.UTF_8);
    public static final int port = Integer.parseInt((String) properties.get("port"));

    // 远程服务器地址
    public static final InetSocketAddress inetSocketAddress = loadInetSocketAddress();

    private static Properties loadProperties()
    {
        Properties properties = new Properties();
        try
        {
            properties.load(new FileInputStream("client.properties"));
        } catch (IOException e)
        {
            throw new RuntimeException(e);
        }
        return properties;
    }

    private static HashSet<Integer> urlHash()
    {
        try (FileInputStream fileInputStream = new FileInputStream("pac.txt");)
        {
            Stream<String> lines = IOUtils.toString(fileInputStream, StandardCharsets.UTF_8).lines();
            Stream<Integer> urlHash = lines.filter(s -> !StringUtils.isBlank(s) || !s.startsWith("#")).map(s -> s.replace(".", "").toLowerCase().hashCode());
            return new HashSet<>(urlHash.toList());
        } catch (IOException e)
        {
            throw new RuntimeException(e);
        }
    }

    private static InetSocketAddress loadInetSocketAddress()
    {
        try (FileInputStream fileInputStream = new FileInputStream("config.txt");)
        {
            Stream<String> lines = IOUtils.toString(fileInputStream, StandardCharsets.UTF_8).lines();
            Stream<String> stringStream = lines.filter(s -> !s.startsWith("#")).map(s -> s.replace("[", "").replace("]", ""));
            List<String> list = stringStream.toList();
            Integer seq = Integer.valueOf(list.get(0));
            String host = list.get(seq);
            int i = host.lastIndexOf(":");
            return new InetSocketAddress(host.substring(0, i), Integer.parseInt(host.substring(i + 1, host.length())));
        } catch (IOException e)
        {
            throw new RuntimeException(e);
        }
    }
}
